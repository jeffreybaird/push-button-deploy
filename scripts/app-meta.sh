#!/usr/bin/env bash
#
# app-meta.sh — parse APP_NAME (OTP app atom) and APP_MODULE (base module) from
# a Phoenix app's mix.exs. App-name-agnostic single source of truth, reused by
# the release-task tooling and the bootstrap (Epic 6).
#
# Source it:   . scripts/app-meta.sh ; APP=$(app_name DIR) ; MOD=$(app_module DIR)
# Or run it:   scripts/app-meta.sh DIR   # prints "APP_NAME=... APP_MODULE=..."
#
# Portable: BSD/macOS grep -E -o + sed -E.
set -euo pipefail

# Resolve a dir-or-mixfile argument to a mix.exs path.
_mixfile() {
  local arg="${1:-.}"
  if [ -d "$arg" ]; then printf '%s/mix.exs' "$arg"; else printf '%s' "$arg"; fi
}

# OTP app atom, e.g. `app: :my_app` -> my_app. The first `app:` whose value is an
# atom (skips dep lines like `app: false`).
app_name() {
  local f; f="$(_mixfile "${1:-.}")"
  [ -f "$f" ] || { echo "ERROR: mix.exs not found: $f" >&2; return 1; }
  local v
  v="$(grep -Eo 'app:[[:space:]]*:[a-z][a-z0-9_]*' "$f" | head -1 | sed -E 's/.*:([a-z0-9_]+)$/\1/')"
  [ -n "$v" ] || { echo "ERROR: could not parse OTP app name from $f" >&2; return 1; }
  printf '%s' "$v"
}

# Base module, e.g. `defmodule MyApp.MixProject` -> MyApp.
app_module() {
  local f; f="$(_mixfile "${1:-.}")"
  [ -f "$f" ] || { echo "ERROR: mix.exs not found: $f" >&2; return 1; }
  local v
  v="$(grep -Eo 'defmodule[[:space:]]+[A-Za-z0-9_.]+\.MixProject' "$f" | head -1 \
        | sed -E 's/defmodule[[:space:]]+([A-Za-z0-9_.]+)\.MixProject/\1/')"
  [ -n "$v" ] || { echo "ERROR: could not parse base module from $f" >&2; return 1; }
  printf '%s' "$v"
}

# When executed (not sourced), print both.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  dir="${1:-.}"
  printf 'APP_NAME=%s APP_MODULE=%s\n' "$(app_name "$dir")" "$(app_module "$dir")"
fi
