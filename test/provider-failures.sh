#!/usr/bin/env bash
# Fail-closed repository/settings operations and whole-workflow selection.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }
warn() { :; }
expect_status() {
  local expected="$1" actual=0; shift
  "$@" > "$WORK/output" 2>&1 || actual=$?
  [ "$actual" -eq "$expected" ] || { cat "$WORK/output" >&2; fail "expected $expected, got $actual"; }
}
. "$ROOT/scripts/provider.sh"
APP_NAME=example; APP_DIR="$WORK/app"; HEAD_SHA=wanted; CI_WORKFLOW=deploy.yml
GITEA_URL=https://code.example; GITEA_OWNER_RESOLVED=owner

# Real status helpers, fake network boundaries. No message parsing for HTTP codes.
gh() {
  case "$*" in
    'api user --jq .login') printf 'owner\n' ;;
    'repo view --json nameWithOwner -q .nameWithOwner') printf 'owner/example\n' ;;
    'api --method '*)
      [ "${CONNECTION_ERROR:-0}" = 0 ] || return 7
      printf 'HTTP/2 %s\r\nContent-Type: application/json\r\n' "$CODE"
      [ "$CODE" -lt 400 ] ;;
    *) return 99 ;;
  esac
}
gitea_api_status() { [ "${CONNECTION_ERROR:-0}" = 0 ] || return 7; printf '%s' "$CODE"; }
for provider in github gitea; do
  GIT_PROVIDER="$provider"
  CODE=200 expect_status 0 repo_exists
  CODE=404 expect_status 1 repo_exists
  for CODE in 401 403 429 500 503; do
    expect_status 2 repo_exists
    expect_status 2 var_delete OLD
  done
  CONNECTION_ERROR=1 expect_status 2 repo_exists
  CONNECTION_ERROR=1 expect_status 2 var_delete OLD
  CODE=404 expect_status 0 var_delete OLD
  CODE=204 expect_status 0 var_delete OLD
  CODE=204 repo_exists > "$WORK/output" 2>&1 && fail 'unexpected lookup status accepted'
done

# Real ensure_repo must not mutate an existing origin or attempt remote writes
# when its adapter cannot establish existence, even when caller checks failure.
mkdir -p "$APP_DIR"
git -C "$APP_DIR" init -q
original=https://code.example/original.git
git -C "$APP_DIR" remote add origin "$original"
. "$ROOT/scripts/bootstrap/repository.sh"
repo_create() { printf 'create\n' >> "$WORK/writes"; }
provider_git_push() { printf 'push\n' >> "$WORK/writes"; }
for provider in github gitea; do
  GIT_PROVIDER="$provider"
  CODE=403 expect_status 1 ensure_repo
  [ "$(git -C "$APP_DIR" remote get-url origin)" = "$original" ]
  [ ! -e "$WORK/writes" ]
done

# The requested run may be on a later page than another workflow for this SHA.
GIT_PROVIDER=gitea
cat > "$WORK/page1" <<'JSON'
{"total_count":3,"workflow_runs":[
 {"id":100,"head_sha":"wanted","path":"other.yml@refs/heads/main","status":"completed","conclusion":"success"},
 {"id":90,"head_sha":"wanted","path":"deploy.yml@refs/heads/main","status":"completed","conclusion":"failure"}]}
JSON
cat > "$WORK/page2" <<'JSON'
{"total_count":3,"workflow_runs":[
 {"id":95,"head_sha":"wanted","path":"deploy.yml@refs/heads/main","status":"in_progress"}]}
JSON
gitea_api() {
  printf '%s\n' "$2" >> "$WORK/queries"
  case "$2" in
    *'actions/runs?head_sha=wanted&limit=50&page=1') cat "$WORK/page1" ;;
    *'actions/runs?head_sha=wanted&limit=50&page=2') cat "$WORK/page2" ;;
    *) return 99 ;;
  esac
}
[ "$(ci_run_row)" = '95 in_progress ' ]
[ "$(wc -l < "$WORK/queries" | tr -d ' ')" = 2 ]
# The old API's individually successful job lacks a full run path: reject it.
printf '{"workflow_runs":[{"id":1,"head_sha":"wanted","workflow_id":"deploy.yml","status":"success"}]}' > "$WORK/page1"
expect_status 2 ci_run_row
for bad in '<html>error</html>' '{}' '{"workflow_runs":null}' '{"workflow_runs":[{}]}'; do
  printf '%s' "$bad" > "$WORK/page1"
  expect_status 2 ci_run_row
done
printf '{"total_count":0,"workflow_runs":[]}' > "$WORK/page1"
[ -z "$(ci_run_row)" ]
# Full-workflow completion is the only success; every row must match SHA + path.
for path in deploy.yml .gitea/workflows/deploy.yml .github/workflows/deploy.yml; do
  jq -n --arg path "$path@refs/heads/main" '{total_count:1,workflow_runs:[{id:95,head_sha:"wanted",path:$path,status:"completed",conclusion:"success"}]}' > "$WORK/page1"
  [ "$(ci_run_row)" = '95 completed success' ]
done
# A missing workflow identity must never match implicitly.
jq '.workflow_runs[0].path="other.yml@refs/heads/main"' "$WORK/page1" > "$WORK/changed"
mv "$WORK/changed" "$WORK/page1"
[ -z "$(ci_run_row)" ]
gitea_api() { return 22; }
expect_status 2 ci_run_row

# Polling errors cannot be mistaken for an empty queue or a healthy website.
. "$ROOT/scripts/deployment.sh"
ci_run_row() { return 2; }
expect_status 2 wait_for_workflow_success "$APP_DIR" deploy.yml wanted '' 0
# Seeding must propagate failure to disable staging even in a conditional.
GIT_PROVIDER=github
needs_droplet() { return 0; }
is_static() { return 0; }
staging_enabled() { return 1; }
secret_set() { cat >/dev/null; }
var_set() { :; }
var_delete() { return 2; }
DIGITALOCEAN_ACCESS_TOKEN=fixture; SSH_PRIVATE_KEY="$WORK/key"
printf fixture > "$SSH_PRIVATE_KEY"
DOMAIN=example.test; APP_IP=127.0.0.1; FW_ID=1; APP_SLUG=example; DATABASE_BACKEND=none
expect_status 1 seed_ci
printf 'provider failure and workflow identity checks passed\n'
