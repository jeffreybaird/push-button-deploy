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

# Ensure Caddy is up (first deploy) and clear any orphaned pre-blue/green 'app'
# container — safe to do only now, after the new color is healthy.
docker compose up -d --remove-orphans caddy

if [ -n "$active" ] && [ "$active" != "$new" ]; then
  docker compose stop "$active"
  docker compose rm -f "$active"
fi
echo "swap: $new is live"
