#!/usr/bin/env bash
#
# ensure-db-tls.sh — make config/runtime.exs configure the Repo for TLS.
#
# DO managed Postgres REJECTS non-TLS connections, and Ecto does NOT infer SSL
# from the database URL. Phoenix ships `# ssl: true,` commented out, so a stock
# app silently fails to connect. This script activates it (idempotently) and
# adds ssl_opts. Run with --check to only assert (CI/bootstrap gate) — it exits
# non-zero and loudly if TLS config is absent.
#
# v1 uses `verify: :verify_none` (encrypted, cert not chain-verified). Story 7.3
# upgrades to verify_peer with DO's CA.
#
# Usage:
#   scripts/ensure-db-tls.sh [app_dir]            # patch + verify
#   scripts/ensure-db-tls.sh --check [app_dir]    # verify only, no edits
#
# Portable: BSD/macOS awk + grep, no GNU-only flags.
set -euo pipefail

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
APP_DIR="${1:-.}"
RT="$APP_DIR/config/runtime.exs"

[ -f "$RT" ] || { echo "ERROR: not found: $RT" >&2; exit 1; }

# An ACTIVE ssl line: optional leading whitespace, then ssl: true (not '# ssl:').
has_active_ssl() { grep -Eq '^[[:space:]]*ssl:[[:space:]]*true' "$1"; }
has_ssl_opts()   { grep -Eq '^[[:space:]]*ssl_opts:' "$1"; }

verify() {
  if has_active_ssl "$RT" && has_ssl_opts "$RT"; then
    echo "OK: $RT configures the Repo with ssl: true + ssl_opts."
    return 0
  fi
  echo "FAIL: $RT does NOT set ssl: true + ssl_opts for the Repo." >&2
  echo "DO managed Postgres rejects non-TLS connections and Ecto won't infer" >&2
  echo "TLS from the URL. Run: scripts/ensure-db-tls.sh $APP_DIR" >&2
  exit 1
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  verify
fi

# Already compliant — nothing to do.
if has_active_ssl "$RT" && has_ssl_opts "$RT"; then
  verify
fi

tmp="$RT.tls.tmp"

if grep -Eq '^[[:space:]]*#[[:space:]]*ssl:[[:space:]]*true' "$RT"; then
  # Case A: replace the commented `# ssl: true,` hint with active config.
  awk '
    /^[[:space:]]*#[[:space:]]*ssl:[[:space:]]*true/ {
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
      print indent "ssl: true,"
      print indent "ssl_opts: [verify: :verify_none],"
      next
    }
    { print }
  ' "$RT" > "$tmp"
elif has_active_ssl "$RT"; then
  # Case B: ssl: true present but ssl_opts missing — add it right after.
  awk '
    !done && /^[[:space:]]*ssl:[[:space:]]*true/ {
      print
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH)
      print indent "ssl_opts: [verify: :verify_none],"
      done = 1
      next
    }
    { print }
  ' "$RT" > "$tmp"
else
  # Case C: no hint at all — insert after the `...Repo,` config header line.
  awk '
    !done && /^[[:space:]]*config[[:space:]]+:[^,]+,[[:space:]]*[A-Za-z0-9_.]+\.Repo,[[:space:]]*$/ {
      print
      match($0, /^[[:space:]]*/); indent = substr($0, 1, RLENGTH) "  "
      print indent "ssl: true,"
      print indent "ssl_opts: [verify: :verify_none],"
      done = 1
      next
    }
    { print }
  ' "$RT" > "$tmp"
fi

mv "$tmp" "$RT"
echo "Patched $RT (ssl: true + ssl_opts)."
verify
