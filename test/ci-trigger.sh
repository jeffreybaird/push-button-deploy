#!/usr/bin/env bash
# Exercise commit_push with real local Git repositories; fake only the CI API.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
cat > "$WORK/driver.sh" <<'DRIVER'
set -euo pipefail
. "$ROOT/scripts/deployment.sh"
log() { :; }
ci_run_row() {
  [ "$1" = "$APP_DIR" ] && [ "$2" = deploy.yml ] || return 99
  [ "$3" = "$(git -C "$APP_DIR" rev-parse HEAD)" ] || return 99
  printf 'lookup\n' >> "$CASE/events"
  case "$CASE" in */lookup-fails) return 2 ;; esac
  cat "$CASE/run"
}
provider_git_push() {
  printf 'push\n' >> "$CASE/events"
  git push "$@"
  # Model a provider registering the new run before git push returns to its caller.
  printf '42 completed success\n' > "$CASE/run"
}
ci_dispatch_deploy() { printf 'dispatch\n' >> "$CASE/events"; }
CI_WORKFLOW=deploy.yml
commit_push
printf '%s\n' "$HEAD_SHA" "$CI_AFTER_RUN_ID" > "$CASE/result"
DRIVER

for scenario in changed unchanged empty running push-fails lookup-fails; do
  export CASE="$WORK/$scenario" ROOT
  export APP_DIR="$CASE/app"
  mkdir -p "$CASE"
  git init -q --bare "$CASE/remote.git"
  git init -q -b main "$APP_DIR"
  git -C "$APP_DIR" config user.name 'Repository test'
  git -C "$APP_DIR" config user.email test@example.invalid
  git -C "$APP_DIR" config commit.gpgsign false
  printf 'initial\n' > "$APP_DIR/app.txt"
  git -C "$APP_DIR" add app.txt
  git -C "$APP_DIR" -c commit.gpgsign=false commit -qm initial
  git -C "$APP_DIR" remote add origin "$CASE/remote.git"
  git -C "$APP_DIR" push -qu origin main
  before="$(git -C "$APP_DIR" rev-parse HEAD)"
  printf '41 completed failure\n' > "$CASE/run"
  case "$scenario" in
    changed) printf 'changed\n' >> "$APP_DIR/app.txt" ;;
    empty) : > "$CASE/run" ;;
    running) printf '41 in_progress \n' > "$CASE/run" ;;
    push-fails) git -C "$APP_DIR" remote set-url origin "$CASE/missing.git" ;;
  esac
  status=0
  "$BASH" "$WORK/driver.sh" > "$CASE/output" 2>&1 || status=$?
  if [ "$scenario" = lookup-fails ]; then
    [ "$status" -eq 2 ]
    [ ! -e "$CASE/result" ]
    [ "$(cat "$CASE/events")" = lookup ]
    continue
  elif [ "$scenario" = push-fails ]; then
    [ "$status" -ne 0 ]
    [ ! -e "$CASE/result" ]
    assert_not grep -q dispatch "$CASE/events"
  else
    [ "$status" -eq 0 ] || { cat "$CASE/output" >&2; exit 1; }
    [ "$(head -1 "$CASE/result")" = "$(git -C "$APP_DIR" rev-parse HEAD)" ]
    if [ "$scenario" = changed ]; then
      [ "$(git -C "$APP_DIR" rev-parse HEAD)" != "$before" ]
      [ "$(tail -1 "$CASE/result")" = 41 ]
      assert_not grep -q dispatch "$CASE/events"
      # The source change really reached the bare remote.
      [ "$(git --git-dir="$CASE/remote.git" show main:app.txt)" = $'initial\nchanged' ]
    else
      [ "$(git -C "$APP_DIR" rev-parse HEAD)" = "$before" ]
      if [ "$scenario" = running ]; then
        [ -z "$(tail -1 "$CASE/result")" ]
        assert_not grep -q dispatch "$CASE/events"
      else
        grep -Fxq dispatch "$CASE/events"
      fi
    fi
  fi
  [ "$(head -2 "$CASE/events")" = $'lookup\npush' ]
  printf 'PASS CI trigger: %s\n' "$scenario"
done
