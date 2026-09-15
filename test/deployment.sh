#!/usr/bin/env bash
# Offline checks for CI identity and the CI-before-HTTPS contract.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/deployment.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { printf '%s\n' "$*"; }
sleep() { :; }
ci_run_row() {
  [ "$1" = "$APP_DIR" ] && [ "$2" = deploy.yml ] && [ "$3" = abc123 ]
  local row
  row="$(head -1 "$WORK/runs")"
  sed '1d' "$WORK/runs" > "$WORK/next"
  mv "$WORK/next" "$WORK/runs"
  printf '%s\n' "$row"
}
curl() { touch "$WORK/https-called"; return 0; }
diagnose_ci() { printf '%s\n' "$*" >&2; exit 1; }
diagnose() { exit 1; }
APP_DIR="$WORK"; CI_WORKFLOW=deploy.yml; HEAD_SHA=abc123
CI_AFTER_RUN_ID=10; DOMAIN=example.invalid; LIVE_TIMEOUT_SECS=0

# An old successful website cannot conceal a failed deployment.
printf '11 completed failure\n' > "$WORK/runs"
if ( confirm_live ); then echo 'FAIL: failed CI accepted' >&2; exit 1; fi
[ ! -e "$WORK/https-called" ]

# A prior successful run for the same commit cannot satisfy a new attempt.
printf '10 completed success\n' > "$WORK/runs"
if ( confirm_live ); then echo 'FAIL: stale CI accepted' >&2; exit 1; fi
[ ! -e "$WORK/https-called" ]

# Registration delay and a stale result are tolerated until the new run appears.
LIVE_TIMEOUT_SECS=30
printf '\n10 completed failure\n11 in_progress \n11 completed success\n' > "$WORK/runs"
confirm_live
[ -e "$WORK/https-called" ]

# An existing running workflow may be reused without requiring a new run ID.
CI_AFTER_RUN_ID=""
printf '10 completed success\n' > "$WORK/runs"
confirm_ci

# A push can register its run immediately. Baseline lookup must precede it.
git() {
  case "$*" in
    *'rev-parse HEAD') printf 'abc123\n' ;;
    *'rev-parse origin/main')
      if [ -e "$WORK/pushed" ]; then printf 'abc123\n'; else printf 'old\n'; fi ;;
    *) : ;;
  esac
}
provider_git_push() {
  touch "$WORK/pushed"
  printf '12 completed success\n' > "$WORK/runs"
}
printf '11 completed failure\n' > "$WORK/runs"
commit_push
[ "$CI_AFTER_RUN_ID" = 11 ]
confirm_ci
echo 'deployment checks passed'
