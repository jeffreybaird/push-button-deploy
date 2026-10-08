#!/usr/bin/env bash
# First bootstrap: real local Git and provider adapter; only GitHub API doubled.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
log() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/provider.sh"
. "$ROOT/scripts/deployment.sh"
GIT_PROVIDER=github; CI_WORKFLOW=deploy.yml; APP_NAME=example
for scenario in fresh auth-failure network-failure malformed; do
  APP_DIR="$WORK/$scenario/app"; remote="$WORK/$scenario/remote.git"
  mkdir -p "$APP_DIR/.github/workflows"
  git init -q --bare "$remote"
  git -C "$APP_DIR" init -q -b main
  git -C "$APP_DIR" config user.name 'Repository test'
  git -C "$APP_DIR" config user.email test@example.invalid
  git -C "$APP_DIR" config commit.gpgsign false
  git -C "$APP_DIR" remote add origin "$remote"
  printf 'name: deploy\n' > "$APP_DIR/.github/workflows/deploy.yml"
  gh() {
    [ "$PWD" = "$APP_DIR" ] || return 99
    [ "$1" = api ] || { echo 'workflow is not registered before first push' >&2; return 1; }
    case "$*" in *'repos/{owner}/{repo}/actions/runs?head_sha='*'&per_page=100&page=1'*) ;; *) return 99 ;; esac
    case "$scenario" in
      fresh) printf '{"total_count":0,"workflow_runs":[]}\n' ;;
      auth-failure) echo 'HTTP401 fixture' >&2; return 1 ;;
      network-failure) return 7 ;;
      malformed) printf '{"workflow_runs":null}\n' ;;
    esac
  }
  status=0
  # Separate process preserves errexit behavior of deployment commands.
  export ROOT WORK scenario APP_DIR APP_NAME GIT_PROVIDER CI_WORKFLOW
  export -f gh log fail
  bash -c 'set -euo pipefail
    . "$ROOT/scripts/provider.sh"
    . "$ROOT/scripts/deployment.sh"
    commit_push
    printf "%s" "$CI_AFTER_RUN_ID" > "$WORK/$scenario/previous"
  ' > "$WORK/$scenario/output" 2>&1 || status=$?
  if [ "$scenario" = fresh ]; then
    [ "$status" = 0 ] || { cat "$WORK/$scenario/output" >&2; exit 1; }
    [ "$(git --git-dir="$remote" show main:.github/workflows/deploy.yml)" = 'name: deploy' ]
    [ -f "$WORK/$scenario/previous" ]
    [ ! -s "$WORK/$scenario/previous" ]
  else
    [ "$status" = 2 ] || fail "$scenario: expected query failure2, got$status"
    [ -z "$(git --git-dir="$remote" for-each-ref --format='%(refname)' refs/heads)" ]
    [ ! -e "$WORK/$scenario/previous" ]
  fi
done
echo 'GitHub first push and fail-closed query checks passed'
