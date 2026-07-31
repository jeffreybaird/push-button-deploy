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

# ---- completeness guard -------------------------------------------------------
# Every service compose defines must have a container by now. `backup` once
# shipped in compose.yaml for a full deploy without ever starting — it has no
# dependent, so nothing pulled it in, and the deploy still reported success. A
# green deploy that silently omits part of the stack is the failure this catches,
# and it catches it for services that don't exist yet, not just that one.
#
# Compared on PRESENCE, not on running state, because db_init is a one-shot that
# exits 0 by design and is therefore present-but-stopped. A container that
# started and later died is a different failure: `restart: unless-stopped` keeps
# retrying it and the logs show why.
#
# Excluded from the comparison:
#   - services behind a profile (migrate) — compose already omits those from
#     `config --services`
#   - the idle color, deliberately removed just above; only "$new" should exist
expected="$(docker compose config --services | grep -vxE 'app_(blue|green)'; printf '%s\n' "$new")"
present="$(docker compose ps -a --services)"

missing=""
for svc in $expected; do
  printf '%s\n' "$present" | grep -qx "$svc" || missing="$missing $svc"
done

if [ -n "$missing" ]; then
  echo "swap: FAILED — compose defines services that never started:$missing" >&2
  echo "swap: $new is live and serving, but the stack is incomplete." >&2
  echo "swap: a service with no depends_on must be named explicitly above." >&2
  exit 1
fi

echo "swap: $new is live"
