#!/usr/bin/env bash
#
# bootstrap.sh — kept so that every existing note, README line and shell-history entry
# still works. This tool is a command now: the work lives in lib/pbd/ and
# bin/pbd is what runs it.
#
#   ./bootstrap.sh <args>   ==   pbd bootstrap <args>
#
# Nothing here does any work — it forwards, which is why the two can never drift.
set -euo pipefail

printf '\033[33m%s: deprecated — this is `pbd %s` now (same arguments)\033[0m\n' "bootstrap.sh" "bootstrap" >&2

DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$DIR/bin/pbd" bootstrap "$@"
