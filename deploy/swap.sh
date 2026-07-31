#!/usr/bin/env bash
#
# swap.sh — health-checked blue/green swap on the droplet (story 7.2).
# Run by the deploy/rollback workflows over SSH: bash /root/swap.sh
#
# Whichever color is running stays up and serving while the OTHER color starts
# from the image pinned in .env. `up --wait` blocks until that container's
# healthcheck passes — and fails the deploy if it never does, leaving the old
# color untouched. Only after the new color is healthy does the old one stop.
set -euo pipefail
cd "$(dirname "$0")"

active="$(docker compose ps --services --status running | grep -E '^app_(blue|green)$' | head -n1 || true)"
if [ "$active" = "app_blue" ]; then new="app_green"; else new="app_blue"; fi
echo "swap: active=${active:-none} -> starting $new"

# Fails loudly (non-zero) if the new color never turns healthy; the old color
# is still running and serving in that case.
docker compose up -d --wait "$new"

# Ensure the color-independent services are up (first deploy, or a service added
# to compose.yaml since the last one) and clear any orphaned pre-blue/green 'app'
# container — safe to do only now, after the new color is healthy.
#
# litestream needs no mention: the app colors depend_on it, so `up` starts it.
# `backup` has no dependent, so nothing would ever start it otherwise — and it
# exists only on the SQLite stack, hence the check. This script is shared by both
# backends, and naming a service the Postgres stack lacks would fail the deploy.
extra="caddy"
if docker compose config --services 2>/dev/null | grep -qx backup; then
  extra="$extra backup"
fi

# Unquoted on purpose: $extra is a word list of service names, not one argument.
# shellcheck disable=SC2086
docker compose up -d --remove-orphans $extra

if [ -n "$active" ] && [ "$active" != "$new" ]; then
  docker compose stop "$active"
  docker compose rm -f "$active"
fi
echo "swap: $new is live"
