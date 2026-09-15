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

github_ci_run_row() {
  ( cd "$APP_DIR" \
    && gh run list --workflow "$CI_WORKFLOW" --commit "$HEAD_SHA" --limit 1 \
         --json databaseId,status,conclusion \
         --jq '.[0] // empty | if (.databaseId | type) != "number" or (.status | type) != "string" then error("invalid workflow run") else "\(.databaseId) \(.status) \(.conclusion // "")" end' 2>/dev/null
  ) || { provider_error "GitHub workflow query failed"; return 2; }
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
