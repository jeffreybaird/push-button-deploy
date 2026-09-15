# Full workflow runs require Gitea >= 1.25. Individual task status cannot
# establish workflow success. See README.md for the source API references.

gitea_run_entries() { # raw JSON -> validated run array
  printf '%s' "$1" | jq -ce '
    (if type == "array" then . else .workflow_runs end)
    | if type != "array" then error("expected workflow_runs array") else . end
    | if all(.[]; (.id | type == "number") and (.head_sha | type == "string")
        and (.path | type == "string") and (.status | type == "string"))
      then . else error("invalid workflow run identity") end
  ' 2>/dev/null || { provider_error "malformed Gitea workflow response"; return 2; }
}

gitea_normalize_run_row() { # run array, commit, workflow -> id status conclusion
  local entries="$1" commit="$2" workflow="$3"
  printf '%s' "$entries" | jq -r --arg sha "$commit" --arg workflow "$workflow" '
    def workflow_file: split("@")[0] | sub("^\\.(gitea|github)/workflows/"; "");
    [.[] | select(.head_sha == $sha and (.path | workflow_file) == $workflow)]
    | sort_by(.id, (.run_attempt // 1)) | last
    | if . == null then empty
      elif .status == "completed" then
        "\(.id) completed \(.conclusion // "unknown")"
      elif .status == "queued" or .status == "waiting" or .status == "pending" or .status == "in_progress" then "\(.id) in_progress "
      else error("unknown workflow status") end
  ' 2>/dev/null || { provider_error "invalid Gitea workflow status"; return 2; }
}

gitea_ci_run_row() {
  local page=1 raw entries count total seen=0 all='[]' sha
  sha="$(printf '%s' "$HEAD_SHA" | jq -sRr @uri)" || return 2
  # Traverse every page for this commit so a busy repository cannot hide the
  # requested workflow behind a newer run of a different workflow.
  while [ "$page" -le 100 ]; do
    raw="$(gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/runs?head_sha=$sha&limit=50&page=$page")" \
      || { provider_error "Gitea workflow query failed"; return 2; }
    entries="$(gitea_run_entries "$raw")" || return 2
    count="$(printf '%s' "$entries" | jq length)"
    all="$(printf '%s\n%s' "$all" "$entries" | jq -sc 'add')" || return 2
    seen=$((seen + count))
    total="$(printf '%s' "$raw" | jq -r 'if type == "object" then .total_count // empty else empty end')"
    if [ -n "$total" ]; then
      case "$total" in *[!0-9]*) provider_error "invalid Gitea pagination total"; return 2 ;; esac
      [ "$seen" -lt "$total" ] || break
      [ "$count" -gt 0 ] || { provider_error "incomplete Gitea pagination"; return 2; }
    else
      [ "$count" -ge 50 ] || break
    fi
    page=$((page + 1))
  done
  [ "$page" -le 100 ] || { provider_error "Gitea run query exceeded pagination limit"; return 2; }
  gitea_normalize_run_row "$all" "$HEAD_SHA" "$CI_WORKFLOW"
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
  local raw
  raw="$(gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/runs?limit=3")" || return 2
  printf '%s' "$raw" | jq -r '.workflow_runs[] | "\(.id)\t\(.path)\t\(.status)\t\(.conclusion // "")"'
}
