#!/usr/bin/env bash
# Match complete GitHub workflow identity across repository run pages.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/provider.sh"
GIT_PROVIDER=github; APP_DIR="$WORK"; APP_NAME=example
HEAD_SHA=wanted; CI_WORKFLOW=deploy.yml
expect_error() {
  local status=0
  ci_run_row > "$WORK/error" 2>&1 || status=$?
  [ "$status" = 2 ] || fail "expected fatal workflow query, got$status"
}
gh() {
  [ "$PWD" = "$APP_DIR" ] || return 99
  [ "$1" = api ] || return 99
  printf '%s\n' "$*" >> "$WORK/queries"
  case "$*" in
    *'repos/{owner}/{repo}/actions/runs?head_sha=wanted&per_page=100&page=1'*) cat "$WORK/page1" ;;
    *'repos/{owner}/{repo}/actions/runs?head_sha=wanted&per_page=100&page=2'*)
      [ "${PAGE2_FAIL:-0}" = 0 ] || return 7
      cat "$WORK/page2" ;;
    *) return 99 ;;
  esac
}
cat > "$WORK/page1" <<'JSON'
{"total_count":6,"workflow_runs":[
 {"id":999,"head_sha":"other","path":".github/workflows/deploy.yml","status":"completed","conclusion":"success"},
 {"id":998,"head_sha":"wanted","path":".github/workflows/not-deploy.yml","status":"completed","conclusion":"success"},
 {"id":997,"head_sha":"wanted","path":"nested/deploy.yml","status":"completed","conclusion":"success"},
 {"id":996,"head_sha":"wanted","path":".gitea/workflows/deploy.yml","status":"completed","conclusion":"success"},
 {"id":7,"head_sha":"wanted","path":".github/workflows/deploy.yml","status":"completed","conclusion":"failure"}]}
JSON
printf '{"total_count":6,"workflow_runs":[{"id":8,"head_sha":"wanted","path":".github/workflows/deploy.yml","status":"in_progress","conclusion":null}]}\n' > "$WORK/page2"
[ "$(ci_run_row)" = '8 in_progress ' ]
[ "$(wc -l < "$WORK/queries" | tr -d ' ')" = 2 ]
# An inaccessible later page cannot silently reuse an earlier successful result.
PAGE2_FAIL=1 expect_error
printf '{"total_count":6,"workflow_runs":[]}\n' > "$WORK/page2"
expect_error
for bad in '<html>failure</html>' '{}' '{"workflow_runs":null}' \
           '{"total_count":"invalid","workflow_runs":[]}' \
           '{"total_count":1,"workflow_runs":[{}]}' \
           '{"total_count":1,"workflow_runs":[{"id":1,"head_sha":"wanted","status":"completed"}]}' ; do
  printf '%s\n' "$bad" > "$WORK/page1"
  expect_error
done
# Valid nonmatching workflow runs are an empty queue, not an error or success.
printf '{"total_count":1,"workflow_runs":[{"id":99,"head_sha":"wanted","path":".github/workflows/other.yml","status":"completed","conclusion":"success"}]}\n' > "$WORK/page1"
[ -z "$(ci_run_row)" ]
echo 'GitHub workflow identity and pagination checks passed'
