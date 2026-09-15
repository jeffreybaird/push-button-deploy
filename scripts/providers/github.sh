# GitHub adapter. gh owns authentication and resolves repository context from
# the current directory except where APP_NAME is explicitly supplied.

github_ci_auth_check() {
  gh auth status >/dev/null 2>&1 || fail "gh not authenticated — run: gh auth login"
}

github_repo_exists() { gh repo view "$APP_NAME" >/dev/null 2>&1; }
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
github_var_delete() { gh variable delete "$1" >/dev/null 2>&1 || true; }

github_ci_run_row() {
  ( cd "$APP_DIR" \
    && gh run list --workflow "$CI_WORKFLOW" --commit "$HEAD_SHA" --limit 1 \
         --json databaseId,status,conclusion \
         --jq '.[0] // empty | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null
  ) || true
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
