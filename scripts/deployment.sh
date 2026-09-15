# Deployment orchestration and independently testable wait operations.
# Requires log(), provider.sh, and application config for the diagnostic wrappers.

# Commit locally, capture the previous run before pushing, then trigger CI.
# Outputs HEAD_SHA and CI_AFTER_RUN_ID for the confirmation step.
commit_push() {
  log "commit + push (triggers CI)"
  local before after previous_row
  before="$(git -C "$APP_DIR" rev-parse origin/main 2>/dev/null || echo none)"
  ( cd "$APP_DIR"
    git add -A
    if git diff --cached --quiet; then
      log "nothing new to commit"
    else
      git commit -q -m "chore: wire push-button deploy pipeline"
    fi
  )
  HEAD_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"
  previous_row="$(ci_run_row "$APP_DIR" "$CI_WORKFLOW" "$HEAD_SHA")" || return 2
  CI_AFTER_RUN_ID="${previous_row%% *}"

  ( cd "$APP_DIR"; provider_git_push -u origin main )
  after="$(git -C "$APP_DIR" rev-parse origin/main)"
  if [ "$before" != "$after" ]; then
    return 0
  fi

  case "${previous_row#* }" in
    ""|completed*)
      log "nothing pushed — dispatching $CI_WORKFLOW against main"
      ci_dispatch_deploy ;;
    *)
      log "a workflow for this commit is already running — waiting on it"
      CI_AFTER_RUN_ID="" ;;
  esac
}

# $1 app directory, $2 workflow, $3 commit, $4 previous run to exclude, $5 timeout.
# A healthy website cannot satisfy this check: only this commit's CI success can.
wait_for_workflow_success() {
  local app_dir="$1" workflow="$2" commit="$3" after_run_id="$4" timeout="$5"
  local started=$SECONDS row run_id status conclusion elapsed last_heartbeat=0
  log "waiting for $workflow at $commit (timeout ${timeout}s)..."
  while :; do
    row="$(ci_run_row "$app_dir" "$workflow" "$commit")" || {
      log "CI query failed for $workflow; refusing to infer workflow success"
      return 2
    }
    run_id=""; status=""; conclusion=""
    read -r run_id status conclusion <<< "$row"
    if [ -n "$run_id" ] && [ "$run_id" != "$after_run_id" ]; then
      case "$status $conclusion" in
        "completed success") log "CI GREEN: $workflow passed (run $run_id)"; return 0 ;;
        completed*) log "CI FAILED: $workflow concluded ${conclusion:-without a result} (run $run_id)"; return 1 ;;
      esac
    fi
    elapsed=$((SECONDS - started))
    if [ "$elapsed" -ge "$timeout" ]; then
      log "CI timeout: $workflow has not succeeded after ${timeout}s"
      return 1
    fi
    if [ $((elapsed - last_heartbeat)) -ge 60 ]; then
      log "  still waiting (${elapsed}s) — CI state: ${status:-no run registered yet} ${conclusion}"
      last_heartbeat=$elapsed
    fi
    sleep 10
  done
}

# $1 URL, $2 timeout. Called only after the expected workflow succeeds.
wait_for_https() {
  local url="$1" timeout="$2" started=$SECONDS
  log "waiting for HTTPS at $url (timeout ${timeout}s)..."
  while :; do
    if curl -fsS -o /dev/null --max-time 10 "$url"; then
      log "LIVE: $url"
      return 0
    fi
    if [ $((SECONDS - started)) -ge "$timeout" ]; then return 1; fi
    sleep 10
  done
}

diagnose() {
  {
    printf '\nbootstrap: NOT LIVE — %s\n' "$1"
    printf '\n--- 1. CI Actions (deploy workflow) ---\n'
    ci_diagnose_dump
    printf '\n--- 2. DNS: dig +short %s (expect %s) ---\n' "$DOMAIN" "$APP_IP"
    dig +short "$DOMAIN" || true
    printf '\n--- 3. Caddy logs (last 40 lines) — SHARED across every app on this droplet ---\n'
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      root@"$APP_IP" 'cd /root/caddy && docker compose logs --tail 40 caddy' 2>&1 \
      || echo "(caddy logs unavailable — the shared edge stack may not be up yet)"
    printf '\n--- 4. This app'\''s stack (/root/apps/%s) ---\n' "$APP_SLUG"
    # A static site has no containers: what matters is which release `current`
    # points at, and whether the route file exists.
    if is_static; then
      probe="ls -l /root/apps/$APP_SLUG/current; ls -1t /root/apps/$APP_SLUG/releases 2>/dev/null | head -5"
    else
      probe="cd /root/apps/$APP_SLUG && docker compose ps -a"
    fi
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      root@"$APP_IP" "$probe; cat /root/caddy/sites/$APP_SLUG.caddy" 2>&1 \
      || echo "(app stack not on the droplet yet — the deploy has not reached it)"
    printf '\nnext: %s; after a fix, re-run ./bootstrap.sh (idempotent)\n' "$(ci_watch_hint)"
  } >&2
  exit 1
}


diagnose_ci() {
  {
    printf '\nbootstrap: CI NOT GREEN — %s\n' "$1"
    printf '\n--- CI runs (%s) ---\n' "$CI_WORKFLOW"
    ci_diagnose_dump
    printf '\nnext: %s; after a fix, re-run ./bootstrap.sh (idempotent)\n' "$(ci_watch_hint)"
  } >&2
  exit 1
}


# Keep diagnostics at the orchestration boundary, outside polling primitives.
confirm_ci() {
  wait_for_workflow_success "$APP_DIR" "$CI_WORKFLOW" "$HEAD_SHA" \
    "$CI_AFTER_RUN_ID" "${LIVE_TIMEOUT_SECS:-900}" \
    || diagnose_ci "the expected workflow did not succeed; see the outcome above"
}

confirm_live() {
  confirm_ci
  wait_for_https "https://$DOMAIN" "${LIVE_TIMEOUT_SECS:-900}" \
    || diagnose "deploy succeeded but HTTPS is not answering — check DNS and Caddy"
}
