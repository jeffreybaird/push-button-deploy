# GitHub adapter. gh owns authentication and resolves repository context from
# the current directory except where APP_NAME is explicitly supplied.

github_ci_auth_check() {
  gh auth status >/dev/null 2>&1 || fail "gh not authenticated — run: gh auth login"
}

# gh repo view uses GraphQL, whose generic failure cannot establish absence.
# REST response headers provide an HTTP status without parsing error prose.
github_api_status() { # method, endpoint
  local headers status result=0
  headers="$(gh api --method "$1" --include --silent "$2" 2>/dev/null)" || result=$?
  status="$(printf '%s\n' "$headers" | awk '/^HTTP\// {gsub(/\r/, ""); code=$2} END {print code}')"
  case "$status" in [1-5][0-9][0-9]) ;; *) provider_error "GitHub request failed without an HTTP status"; return 2 ;; esac
  if [ "$result" -ne 0 ] && [ "$status" -lt 400 ]; then
    provider_error "GitHub request did not complete"; return 2
  fi
  printf '%s\n' "$status"
}

github_repo_slug() {
  local owner
  case "$APP_NAME" in
    */*) printf '%s\n' "$APP_NAME" ;;
    *)
      owner="$(gh api user --jq .login)" || { provider_error "could not resolve GitHub repository owner"; return 2; }
      [ -n "$owner" ] || { provider_error "GitHub owner was empty"; return 2; }
      printf '%s/%s\n' "$owner" "$APP_NAME" ;;
  esac
}

github_repo_exists() {
  local slug code
  slug="$(github_repo_slug)" || return 2
  code="$(github_api_status GET "repos/$slug")" || return 2
  provider_repository_status "$code"
}
github_repo_remote_url() { gh repo view "$APP_NAME" --json url -q .url 2>/dev/null; }
github_repo_create() { gh repo create "$APP_NAME" --source=. --private --remote=origin; }
github_repo_delete() {
  gh repo delete --yes \
    || fail "gh repo delete failed — it needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo"
}
github_git_push() { git push "$@"; }

# Preserve stdin through dispatch; secret values are never facade arguments.
github_secret_set() { gh secret set "$1"; }
github_var_set() { gh variable set "$1" -b "$2"; }
github_var_delete() {
  local slug code
  slug="$(gh repo view --json nameWithOwner -q .nameWithOwner)" \
    || { provider_error "could not resolve GitHub repository for variable deletion"; return 2; }
  [ -n "$slug" ] || { provider_error "GitHub repository identity was empty"; return 2; }
  code="$(github_api_status DELETE "repos/$slug/actions/variables/$1")" || return 2
  provider_delete_status "variable $1" "$code"
}

# Validate one repository-runs page and emit count, total and its newest match.
# Python is already required for every app type; GitHub-only CLI projects do
# not require a standalone jq executable.
github_run_page() { # stdin JSON, $1 commit, $2 workflow
  python3 -c '
import json
import sys

try:
    page = json.load(sys.stdin)
    if not isinstance(page, dict):
        raise ValueError("expected repository runs object")
    total, runs = page.get("total_count"), page.get("workflow_runs")
    if type(total) is not int or not 0 <= total <= 1000:
        raise ValueError("invalid total or GitHub filtered-search limit exceeded")
    if not isinstance(runs, list) or len(runs) > 100 or len(runs) > total:
        raise ValueError("invalid workflow_runs page")
    statuses = {"queued", "waiting", "pending", "requested", "in_progress", "completed"}
    newest = None
    for run in runs:
        if (not isinstance(run, dict) or type(run.get("id")) is not int
                or not 0 < run["id"] < 2**63
                or not isinstance(run.get("head_sha"), str)
                or not isinstance(run.get("path"), str)
                or not isinstance(run.get("status"), str)
                or run["status"] not in statuses
                or (run.get("conclusion") is not None
                    and not isinstance(run["conclusion"], str))):
            raise ValueError("invalid workflow run")
        if run["head_sha"] == sys.argv[1] and run["path"] == ".github/workflows/" + sys.argv[2]:
            if newest is None or run["id"] > newest["id"]:
                newest = run
    print(len(runs), total, end="")
    if newest is not None:
        conclusion = newest.get("conclusion") or ""
        if any(char.isspace() for char in conclusion):
            raise ValueError("invalid workflow conclusion")
        print("", newest["id"], newest["status"], conclusion, end="")
    print()
except (ValueError, TypeError, KeyError):
    sys.exit(2)
' "$1" "$2" || { provider_error "malformed or incomplete GitHub workflow response"; return 2; }
}

github_ci_run_row() {
  local page=1 raw parsed count total run_id status conclusion sha
  local seen=0 expected_total="" newest_id=0 newest_row=""
  sha="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$HEAD_SHA")" || return 2
  # A workflow-specific lookup returns 404 before the first push registers it.
  # The repository endpoint instead returns a valid empty run list. Never turn
  # authorization, transport or malformed-data failures into an empty queue.
  while [ "$page" -le 10 ]; do
    raw="$(cd "$APP_DIR" && gh api "repos/{owner}/{repo}/actions/runs?head_sha=$sha&per_page=100&page=$page")" \
      || { provider_error "GitHub workflow query failed"; return 2; }
    parsed="$(printf '%s' "$raw" | github_run_page "$HEAD_SHA" "$CI_WORKFLOW")" || return 2
    read -r count total run_id status conclusion <<< "$parsed"
    [ -n "$expected_total" ] || expected_total="$total"
    if [ "$total" -ne "$expected_total" ]; then
      provider_error "GitHub workflow pagination changed during query"; return 2
    fi
    seen=$((seen + count))
    [ "$seen" -le "$total" ] || { provider_error "invalid GitHub pagination total"; return 2; }
    if [ -n "$run_id" ] && [ "$run_id" -gt "$newest_id" ]; then
      newest_id="$run_id"; newest_row="$run_id $status $conclusion"
    fi
    if [ "$seen" -eq "$total" ]; then
      [ -z "$newest_row" ] || printf '%s\n' "$newest_row"
      return 0
    fi
    [ "$count" -gt 0 ] || { provider_error "incomplete GitHub pagination"; return 2; }
    page=$((page + 1))
  done
  provider_error "GitHub run query exceeded pagination limit"; return 2
}

github_ci_dispatch_deploy() {
  ( cd "$APP_DIR" && gh workflow run "$CI_WORKFLOW" --ref main ) \
    || fail "could not dispatch $CI_WORKFLOW (gh workflow run) — trigger it by hand: gh workflow run $CI_WORKFLOW --ref main"
}
github_ci_watch_hint() { printf 'gh run watch'; }
github_ci_log_hint() { printf 'gh run view --log-failed'; }
github_ci_diagnose_dump() {
  ( cd "$APP_DIR" && gh run list --workflow "$CI_WORKFLOW" --limit 3 ) || echo "(gh run list failed)"
}
