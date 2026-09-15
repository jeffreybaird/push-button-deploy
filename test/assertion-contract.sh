#!/usr/bin/env bash
# Guard the assertion helper against silently accepting unexpected success/errors.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for outcome in 0 1 2; do
  status=0
  "$BASH" -euo pipefail -c '
    . "$1/test/helpers/assertions.sh"
    boundary() { return "$2"; }
    assert_not boundary ignored "$2"
  ' assertions "$ROOT" "$outcome" >/dev/null 2>&1 || status=$?
  if [ "$outcome" = 1 ]; then [ "$status" -eq 0 ]; else [ "$status" -ne 0 ]; fi
done
echo 'assertion contract checks passed'
