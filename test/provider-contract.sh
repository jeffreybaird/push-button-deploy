#!/usr/bin/env bash
# Exercise the public facade against fake gh/curl and local Git repositories.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }

# Sourcing must perform no network operations.
gh() { return 99; }
curl() { return 99; }
GIT_PROVIDER=github; GITEA_URL=https://code.example/; GITEA_TOKEN=fixture-token
. "$ROOT/scripts/provider.sh"
[ "$GITEA_URL" = https://code.example ]
APP_NAME=example; APP_DIR="$WORK/app"; HEAD_SHA=commit; CI_WORKFLOW=ci.yml
mkdir -p "$APP_DIR"
cd "$APP_DIR"

# Keep exact argument boundaries and stdin visible in local fixtures.
gh() {
  printf '%s\n' "$@" > "$WORK/gh-args"
  printf '%s\n' "$PWD" > "$WORK/gh-cwd"
  if [ "$1 $2" = 'secret set' ]; then cat > "$WORK/gh-stdin"; fi
  return "${GH_STATUS:-0}"
}
expect_gh() { printf '%s\n' "$@" > "$WORK/expected"; cmp "$WORK/expected" "$WORK/gh-args"; }
ci_auth_check; expect_gh auth status
repo_exists; expect_gh repo view example
repo_remote_url; expect_gh repo view example --json url -q .url
repo_create; expect_gh repo create example --source=. --private --remote=origin
repo_delete; expect_gh repo delete --yes
printf 'line one\nline "two"\\end' > "$WORK/secret"
secret_set TOKEN < "$WORK/secret"; expect_gh secret set TOKEN
cmp "$WORK/secret" "$WORK/gh-stdin"
var_set DOMAIN 'a value with spaces'; expect_gh variable set DOMAIN -b 'a value with spaces'
GH_STATUS=1 var_delete OLD; expect_gh variable delete OLD
GH_STATUS=1 assert_not repo_exists
GH_STATUS=1 assert_not repo_create
( GH_STATUS=1; ci_auth_check ) > "$WORK/error" 2>&1 && fail 'auth failure was swallowed'
( GH_STATUS=1; repo_delete ) > "$WORK/error" 2>&1 && fail 'delete failure was swallowed'
ci_dispatch_deploy; expect_gh workflow run ci.yml --ref main
[ "$(cat "$WORK/gh-cwd")" = "$APP_DIR" ]
[ "$(ci_watch_hint)" = 'gh run watch' ]
[ "$(ci_log_hint)" = 'gh run view --log-failed' ]
ci_diagnose_dump; expect_gh run list --workflow ci.yml --limit 3

# Test the real Gitea HTTP helpers. Fake only curl, not the API helpers.
curl() {
  local method='' url='' body='' arg status_mode=0
  printf '%s\n' "$@" > "$WORK/curl-args"
  while [ $# -gt 0 ]; do
    arg="$1"; shift
    case "$arg" in
      -X) method="$1"; shift ;;
      -d) body="$1"; shift ;;
      -w) status_mode=1; shift ;;
      -H|-o) shift ;;
      http*) url="$arg" ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >> "$WORK/requests"
  printf '%s' "$body" > "$WORK/body"
  [ "${CURL_STATUS:-0}" -eq 0 ] || return "$CURL_STATUS"
  if [ "$status_mode" = 1 ]; then
    if [ "$method" = POST ]; then printf '%s' "${POST_CODE:-201}"
    else printf '%s' "${HTTP_CODE:-200}"; fi
  else
    case "$url" in
      */user) printf '%s' "${AUTH_BODY:-{\"login\":\"alice\"}}" ;;
      */version) printf '{"version":"%s"}' "${VERSION:-1.24.0+dev}" ;;
      *) printf '{}' ;;
    esac
  fi
}
GIT_PROVIDER=gitea
: > "$WORK/requests"
ci_auth_check
[ "$GITEA_AUTH_LOGIN" = alice ]
[ "$GITEA_OWNER_RESOLVED" = alice ]
GITEA_OWNER=team ci_auth_check
[ "$GITEA_OWNER_RESOLVED" = team ]
( VERSION=1.23.9; ci_auth_check ) > "$WORK/error" 2>&1 && fail 'old version accepted'
( AUTH_BODY='{}'; ci_auth_check ) > "$WORK/error" 2>&1 && fail 'missing login accepted'
( CURL_STATUS=7; ci_auth_check ) > "$WORK/error" 2>&1 && fail 'connection error accepted'
gitea_version_at_least 1.24 1.24
gitea_version_at_least 2.0.0 1.24
assert_not gitea_version_at_least 1.9.9 1.24

HTTP_CODE=200 repo_exists
HTTP_CODE=404 assert_not repo_exists
[ "$(repo_remote_url)" = https://code.example/team/example.git ]
git init -q
repo_create
[ "$(git remote get-url origin)" = https://code.example/team/example.git ]
grep -q 'POST https://code.example/api/v1/orgs/team/repos' "$WORK/requests"
jq -e '.name == "example" and .private == true and .auto_init == false' "$WORK/body" >/dev/null
git remote remove origin
GITEA_OWNER_RESOLVED=alice repo_create
grep -q 'POST https://code.example/api/v1/user/repos' "$WORK/requests"
[ "$(git remote get-url origin)" = https://code.example/alice/example.git ]
git remote remove origin
# Even in a conditional (where errexit is disabled), creation failure must
# propagate before origin is added. A network exit code is preserved exactly.
status=0
CURL_STATUS=7 repo_create || status=$?
[ "$status" -eq 7 ]
[ -z "$(git remote)" ]
HTTP_CODE=204 repo_delete
( HTTP_CODE=403; repo_delete ) > "$WORK/error" 2>&1 && fail 'delete error swallowed'

secret_set TOKEN < "$WORK/secret"
jq -j .data "$WORK/body" > "$WORK/decoded"
cmp "$WORK/secret" "$WORK/decoded"
grep -q 'PUT https://code.example/api/v1/repos/team/example/actions/secrets/TOKEN' "$WORK/requests"
grep -q '^Authorization: token fixture-token$' "$WORK/curl-args"
grep -q '^-fsS$' "$WORK/curl-args"
: > "$WORK/requests"
HTTP_CODE=204 var_set DOMAIN 'quote" and space'
[ "$(wc -l < "$WORK/requests" | tr -d ' ')" = 1 ]
[ "$(jq -r .value "$WORK/body")" = 'quote" and space' ]
: > "$WORK/requests"
HTTP_CODE=404 var_set DOMAIN new
[ "$(wc -l < "$WORK/requests" | tr -d ' ')" = 2 ]
grep -q '^POST .*actions/variables/DOMAIN$' "$WORK/requests"
( HTTP_CODE=403; var_set DOMAIN new ) > "$WORK/error" 2>&1 && fail 'variable error swallowed'
( HTTP_CODE=404; POST_CODE=500; var_set DOMAIN new ) > "$WORK/error" 2>&1 && fail 'create error swallowed'
HTTP_CODE=500 var_delete OLD
POST_CODE=204 ci_dispatch_deploy
jq -e '.ref == "main"' "$WORK/body" >/dev/null
grep -q 'POST https://code.example/api/v1/repos/team/example/actions/workflows/ci.yml/dispatches' "$WORK/requests"
( POST_CODE=500; ci_dispatch_deploy ) > "$WORK/error" 2>&1 && fail 'dispatch error swallowed'
[ "$(ci_watch_hint)" = https://code.example/team/example/actions ]
[ "$(ci_log_hint)" = "$(ci_watch_hint)" ]

# Verify exact push forwarding without network or persisted credentials.
git() { printf '%s\n' "$@" > "$WORK/git-args"; return "${GIT_STATUS:-0}"; }
GIT_PROVIDER=gitea provider_git_push -q origin 'HEAD:refs/heads/a branch'
printf '%s\n' -c 'http.extraHeader=Authorization: token fixture-token' push -q origin 'HEAD:refs/heads/a branch' > "$WORK/expected"
cmp "$WORK/expected" "$WORK/git-args"
GIT_PROVIDER=github provider_git_push -q origin main
printf '%s\n' push -q origin main > "$WORK/expected"
cmp "$WORK/expected" "$WORK/git-args"
GIT_STATUS=1 assert_not provider_git_push origin main
( GIT_PROVIDER=unknown; repo_exists ) > "$WORK/error" 2>&1 && fail 'unknown provider accepted'
printf 'provider contract checks passed\n'
