#!/usr/bin/env bash
# Execute the actual swap script; fake only Docker, never the shell's errexit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/app"
cp "$ROOT/test/fixtures/docker" "$WORK/bin/docker"
chmod +x "$WORK/bin/docker"
cp "$ROOT/deploy/swap.sh" "$WORK/app/swap.sh"
export PATH="$WORK/bin:$PATH"
failures=0

scenario() { # $1 label, $2 active color, $3 supporting services, $4 injected fault
  local label="$1" active="$2" support="$3" fault="$4" candidate=app_blue status=0
  export SWAP_FIXTURE="$WORK/$label"
  mkdir -p "$SWAP_FIXTURE"
  printf '%s\n' "$active" > "$SWAP_FIXTURE/running"
  printf '%s\n' "$active" > "$SWAP_FIXTURE/present"
  printf 'app_blue\napp_green\n' > "$SWAP_FIXTURE/services"
  if [ -n "$support" ]; then printf '%s\n' "$support" >> "$SWAP_FIXTURE/services"; fi
  [ -z "$fault" ] || touch "$SWAP_FIXTURE/$fault"
  [ "$active" != app_blue ] || candidate=app_green
  "$BASH" "$WORK/app/swap.sh" > "$SWAP_FIXTURE/output" 2>&1 || status=$?

  # Assertions are a separate process with errexit enabled. An assertion failure
  # must not be hidden by an enclosing `if function` or `function || handler`.
  if "$BASH" -euo pipefail -c '
    . "$7/test/helpers/assertions.sh"
    fixture="$1"; active="$2"; candidate="$3"; fault="$4"; status="$5"; support="$6"
    if [ -n "$fault" ]; then
      [ "$status" -ne 0 ]
      if [ "$fault" != omit-backup ]; then
        assert_not grep -q "^compose stop " "$fixture/calls"
        assert_not grep -q "^compose rm " "$fixture/calls"
      else
        grep -q "stack is incomplete" "$fixture/output"
      fi
    else
      [ "$status" -eq 0 ]
      grep -Fxq "swap: $candidate is live" "$fixture/output"
      if [ -n "$active" ]; then
        grep -Fxq "compose stop $active" "$fixture/calls"
        grep -Fxq "compose rm -f $active" "$fixture/calls"
      else
        assert_not grep -q "^compose stop " "$fixture/calls"
      fi
      for service in $support; do grep -Fxq "$service" "$fixture/present"; done
    fi
    assert_not grep -Fxq "compose up -d" "$fixture/calls"
    # The idle color must never be started as an incidental supporting service.
    [ "$(grep -c "^compose up .*app_" "$fixture/calls")" -eq 1 ]
  ' assertions "$SWAP_FIXTURE" "$active" "$candidate" "$fault" "$status" "$support" "$ROOT"; then
    printf 'PASS swap: %s\n' "$label"
  else
    printf 'FAIL swap: %s\n' "$label" >&2
    cat "$SWAP_FIXTURE/output" "$SWAP_FIXTURE/calls" >&2
    failures=$((failures + 1))
  fi
}

scenario postgres-blue app_blue '' ''
scenario postgres-green app_green '' ''
scenario first-deploy '' '' ''
scenario sqlite app_blue $'db_init\nlitestream\nbackup' ''
scenario candidate-fails app_blue backup fail-candidate
scenario config-fails app_blue backup fail-config
scenario support-fails app_blue backup fail-support
scenario missing-backup app_blue backup omit-backup
[ "$failures" -eq 0 ]
