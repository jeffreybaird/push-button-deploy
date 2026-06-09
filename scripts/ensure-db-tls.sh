#!/usr/bin/env bash
#
# ensure-db-tls.sh — make config/runtime.exs configure the Repo for TLS.
#
# DO managed Postgres REJECTS non-TLS connections, and Ecto does NOT infer SSL
# from the database URL — a stock app silently fails to connect. This script
# appends a marker-guarded, prod-only config block that always enables TLS,
# and (story 7.3) VERIFIES the server certificate whenever the deploy delivers
# the cluster CA via DATABASE_CA_FILE:
#
#   DATABASE_CA_FILE set    -> verify: :verify_peer + cacertfile + hostname check
#   DATABASE_CA_FILE unset  -> encrypted but unverified (local/one-off runs)
#
# Because the block is appended, Config merging makes it override any earlier
# `ssl:` value for the Repo. Postgrex >= 0.18 expects TLS options under `ssl:`
# (`ssl_opts:` is deprecated) — a leftover ssl_opts line from the pre-7.3
# version of this script is removed.
#
# Usage:
#   scripts/ensure-db-tls.sh [app_dir]            # patch + verify
#   scripts/ensure-db-tls.sh --check [app_dir]    # verify only, no edits
#
# Portable: BSD/macOS awk + grep + sed, no GNU-only flags.
set -euo pipefail

MARKER="push-button-deploy: database TLS"

CHECK_ONLY=0
if [ "${1:-}" = "--check" ]; then CHECK_ONLY=1; shift; fi
APP_DIR="${1:-.}"
RT="$APP_DIR/config/runtime.exs"

[ -f "$RT" ] || { echo "ERROR: not found: $RT" >&2; exit 1; }

verify() {
  if grep -q "$MARKER" "$RT"; then
    echo "OK: $RT carries the TLS config block ($MARKER)."
    return 0
  fi
  echo "FAIL: $RT does NOT configure TLS for the Repo." >&2
  echo "DO managed Postgres rejects non-TLS connections and Ecto won't infer" >&2
  echo "TLS from the URL. Run: scripts/ensure-db-tls.sh $APP_DIR" >&2
  exit 1
}

if [ "$CHECK_ONLY" -eq 1 ]; then
  verify
  exit 0
fi

# Already patched — nothing to do.
if grep -q "$MARKER" "$RT"; then
  verify
  exit 0
fi

# The Repo's app atom + module, from the app's own config line:
#   config :my_app, MyApp.Repo,
repo_line="$(grep -E '^[[:space:]]*config[[:space:]]+:[a-z][a-z0-9_]*,[[:space:]]*[A-Za-z0-9_.]+\.Repo,' "$RT" | head -n1)"
[ -n "$repo_line" ] || { echo "ERROR: no 'config :app, Module.Repo,' line in $RT" >&2; exit 1; }
app_atom="$(printf '%s' "$repo_line" | sed -E 's/^[[:space:]]*config[[:space:]]+:([a-z][a-z0-9_]*),.*/\1/')"
repo_mod="$(printf '%s' "$repo_line" | sed -E 's/^[[:space:]]*config[[:space:]]+:[a-z][a-z0-9_]*,[[:space:]]*([A-Za-z0-9_.]+\.Repo),.*/\1/')"

# Legacy cleanup: the pre-7.3 version injected `ssl_opts: [verify: :verify_none],`
# inline — deprecated under Postgrex >= 0.18, and superseded by the block below.
if grep -Eq '^[[:space:]]*ssl_opts:[[:space:]]*\[verify:[[:space:]]*:verify_none\],?[[:space:]]*$' "$RT"; then
  tmp="$RT.tls.tmp"
  grep -Ev '^[[:space:]]*ssl_opts:[[:space:]]*\[verify:[[:space:]]*:verify_none\],?[[:space:]]*$' "$RT" > "$tmp"
  mv "$tmp" "$RT"
  echo "Removed legacy ssl_opts line from $RT."
fi

cat >> "$RT" <<EOF

# == ${MARKER} ==
# Appended by ensure-db-tls.sh — managed Postgres requires TLS, and Ecto does
# not infer it from the URL. Appended last so Config merging makes this the
# Repo's effective :ssl value. When the deploy delivers the cluster CA
# (DATABASE_CA_FILE), the server certificate is fully verified; without it the
# connection is still encrypted, just not verified.
if config_env() == :prod do
  config :${app_atom}, ${repo_mod},
    ssl:
      (case System.get_env("DATABASE_CA_FILE") do
         nil ->
           [verify: :verify_none]

         cacertfile ->
           [
             verify: :verify_peer,
             cacertfile: cacertfile,
             depth: 3,
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ]
       end)
end
EOF

echo "Patched $RT (appended TLS config block for :${app_atom} / ${repo_mod})."

# The file must still be valid Elixir.
if command -v elixir >/dev/null 2>&1; then
  elixir -e "Code.string_to_quoted!(File.read!(\"$RT\"))" \
    || { echo "ERROR: $RT no longer parses as Elixir — patch bug, please report" >&2; exit 1; }
fi

verify
