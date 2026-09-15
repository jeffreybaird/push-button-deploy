# Gitea Actions requests and normalized run rows.
# /actions/tasks can briefly omit waiting runs. The deployment layer polls.
# Selection remains commit-based; this endpoint does not provide the same
# workflow filtering contract as GitHub's workflow-specific run query.

gitea_normalize_run_row() { # raw JSON, commit -> id status conclusion
  local raw="$1" HEAD_SHA="$2" row id status
  row="$(printf '%s' "$raw" \
    | jq -r --arg sha "$HEAD_SHA" '
        (if type == "array" then . else (.workflow_runs // []) end) as $runs
        | [$runs[]? | select(.head_sha == $sha)]
        | sort_by(.run_number // .id) | last
        | "\(.id // "")\t\(.status // "")"
      ' 2>/dev/null || true)"
  id="${row%%	*}"
  status="${row#*	}"
  [ -n "$id" ] || return 0
  case "$status" in
    success)                   printf '%s completed success\n'   "$id" ;;
    failure)                   printf '%s completed failure\n'   "$id" ;;
    cancelled)                 printf '%s completed cancelled\n' "$id" ;;
    skipped)                   printf '%s completed skipped\n'   "$id" ;;
    running|waiting|blocked)   printf '%s in_progress \n'        "$id" ;;
    *) : ;;
  esac
}

gitea_ci_run_row() {
  local raw
  # Guard the request and parse separately: missing/malformed polling responses
  # yield no row and are retried by deployment.sh (also safe with Bash 3.2 ERR).
  raw="$(gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/tasks" 2>/dev/null || true)"
  [ -n "$raw" ] || return 0
  gitea_normalize_run_row "$raw" "$HEAD_SHA"
}

gitea_ci_dispatch_deploy() {
  local code body
  body='{"ref":"main"}'
  code="$(gitea_api_status POST \
    "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/workflows/$CI_WORKFLOW/dispatches" "$body")" || true
  case "$code" in
    2??) return 0 ;;
    *) fail "gitea: could not dispatch $CI_WORKFLOW (HTTP ${code:-connection error}) — trigger it by hand from $GITEA_URL/$GITEA_OWNER_RESOLVED/$APP_NAME/actions" ;;
  esac
}

gitea_ci_watch_hint() { printf '%s/%s/%s/actions' "$GITEA_URL" "$GITEA_OWNER_RESOLVED" "$APP_NAME"; }
gitea_ci_log_hint() { gitea_ci_watch_hint; }

gitea_ci_diagnose_dump() {
  { gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/tasks?limit=3" 2>/dev/null || true; } \
    | { jq -r '
        (if type == "array" then . else (.workflow_runs // []) end) as $runs
        | $runs[:3][]
        | "\(.id)\t\(.status)\t\((.head_sha // "")[0:8])\t\(.run_started_at // .created_at // "")"
      ' 2>/dev/null || echo "(gitea actions task list failed)"; }
}
