#!/usr/bin/env bash
# Run provider normalization against API fixtures with the real jq expressions.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
have() { command -v "$1" >/dev/null; }
. "$ROOT/scripts/provider.sh"
APP_DIR="$WORK"; APP_NAME=example; HEAD_SHA=wanted; CI_WORKFLOW=deploy.yml
GITEA_OWNER_RESOLVED=owner

gh() {
  # Enforce identity at the gh boundary; evaluate its actual output query.
  [ "$PWD" = "$APP_DIR" ] || return 1
  [ "$1 $2" = 'run list' ] || return 1
  shift 2
  [ "$1 $2 $3 $4 $5 $6" = '--workflow deploy.yml --commit wanted --limit 1' ] || return 1
  shift 6
  [ "$1 $2 $3" = '--json databaseId,status,conclusion --jq' ] || return 1
  jq -r "$4" "$WORK/github.json"
}
GIT_PROVIDER=github
printf '[]\n' > "$WORK/github.json"
[ -z "$(ci_run_row "$APP_DIR" deploy.yml wanted)" ]
printf '[{"databaseId":7,"status":"completed","conclusion":"success"}]\n' > "$WORK/github.json"
[ "$(ci_run_row "$APP_DIR" deploy.yml wanted)" = '7 completed success' ]
# Explicit arguments must override incidental caller globals.
HEAD_SHA=unrelated; CI_WORKFLOW=other.yml
[ "$(ci_run_row "$APP_DIR" deploy.yml wanted)" = '7 completed success' ]
[ "$HEAD_SHA" = unrelated ]
[ "$CI_WORKFLOW" = other.yml ]

gitea_api() {
  [ "$1 $2" = 'GET /repos/owner/example/actions/runs?head_sha=wanted&limit=50&page=1' ] || return 1
  cat "$WORK/gitea.json"
}
GIT_PROVIDER=gitea
for envelope in array object; do
  for spec in 'success completed success' 'failure completed failure' \
              'cancelled completed cancelled' 'skipped completed skipped' \
              'in_progress in_progress' 'waiting in_progress' 'queued in_progress'; do
    read -r upstream expected_status expected_conclusion <<< "$spec"
    jq -n --arg status "$upstream" --arg envelope "$envelope" '
      [{id: 99, run_number: 99, head_sha: "other", path: "deploy.yml@refs/heads/main", status: "completed", conclusion: "success"},
       {id: 7, run_number: 7, head_sha: "wanted", path: ".gitea/workflows/deploy.yml@refs/heads/main",
        status: (if ["success", "failure", "cancelled", "skipped"] | index($status) then "completed" else $status end),
        conclusion: (if ["success", "failure", "cancelled", "skipped"] | index($status) then $status else "" end)},
       {id: 6, run_number: 6, head_sha: "wanted", path: "deploy.yml@refs/heads/main", status: "completed", conclusion: "failure"}]
      | if $envelope == "object" then {workflow_runs: .} else . end
    ' > "$WORK/gitea.json"
    row="$(ci_run_row "$APP_DIR" deploy.yml wanted)"
    read -r id status conclusion <<< "$row"
    [ "$id" = 7 ]
    [ "$status" = "$expected_status" ]
    [ "$conclusion" = "$expected_conclusion" ]
  done
done
for response in '[]' '{"workflow_runs":[]}'; do
  printf '%s\n' "$response" > "$WORK/gitea.json"
  [ -z "$(ci_run_row "$APP_DIR" deploy.yml wanted)" ]
done
GIT_PROVIDER=github
for response in '<html>service unavailable</html>' '[{"status":"completed","conclusion":"success"}]'; do
  printf '%s\n' "$response" > "$WORK/github.json"
  result=0
  ci_run_row "$APP_DIR" deploy.yml wanted > "$WORK/error" 2>&1 || result=$?
  [ "$result" -eq 2 ]
done
echo 'provider run fixture checks passed'
