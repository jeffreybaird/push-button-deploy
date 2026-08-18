#!/usr/bin/env bash
#
# staging-down.sh — destroy a pull-request staging environment on the droplet.
# Run by the staging workflow over SSH, from the droplet's shared edge directory:
#
#   APP_SLUG=<slug>-stg bash /root/caddy/staging-down.sh
#
# It is the exact inverse of what a staging deploy builds:
#
#   1. the stack in /root/apps/<slug>-stg — containers AND volumes (-v), because
#      a PR environment's data is scratch by definition and leaving the volume
#      behind would silently seed the NEXT pull request's environment with it
#   2. the stack directory itself, including the .env the deploy wrote there
#   3. this environment's route out of the shared Caddy, plus the reload
#   4. the site template the staging deploy ships under its own name
#
# What it deliberately does NOT touch: the droplet, the shared Caddy stack, the
# `edge` network, the app's PRODUCTION stack, any other app on the host, and the
# staging DNS record (that is Terraform's, and it is meant to outlive any one PR).
#
# Idempotent and forgiving: an environment that is already gone is a no-op, not a
# failure. A teardown that fails would leave a PR environment serving forever.
#
# Portable: runs on the droplet (Ubuntu), so bash + GNU coreutils are fine.
set -euo pipefail

cd "$(dirname "$0")"

log()  { printf 'staging-down: %s\n' "$*"; }
fail() { printf 'staging-down: %s\n' "$*" >&2; exit 1; }

[ -n "${APP_SLUG:-}" ] || fail "APP_SLUG is required (the STAGING slug, e.g. myapp-stg)"

# The one guard that matters. This script runs `docker compose down -v` and
# `rm -rf` against /root/apps/<slug>; pointed at a production slug it would
# delete a live app and its database. Staging slugs are the only thing it may
# ever be handed, and they always end in -stg.
case "$APP_SLUG" in
  *-stg) ;;
  *) fail "refusing to tear down '$APP_SLUG': not a staging slug (must end in '-stg')" ;;
esac

DIR="/root/apps/$APP_SLUG"
SITE="/root/caddy/sites/${APP_SLUG}.caddy"
# The staging deploy renders the route from its OWN copy of the dynamic site
# template, under a name no other app on the droplet writes (the shared
# site.caddy.tmpl belongs to whichever production deploy ran last, and may be
# the static one).
TMPL="/root/caddy/site.${APP_SLUG}.tmpl"

if [ ! -d "$DIR" ] && [ ! -e "$SITE" ]; then
  log "nothing to do — no $DIR and no $SITE"
  rm -f "$TMPL"
  exit 0
fi

# `down` reads the project name from compose.yaml (${APP_SLUG}, interpolated from
# the .env next to it), so it can only ever reach this environment's containers,
# networks and volumes. Best-effort: a half-built environment (files copied, stack
# never started) must still get cleaned up by the rm below.
if [ -f "$DIR/compose.yaml" ]; then
  log "stopping the stack in $DIR (and removing its volumes)"
  ( cd "$DIR" && docker compose down -v --remove-orphans ) || log "  compose down failed — removing the files anyway"
fi

rm -rf "$DIR" "$SITE" "$TMPL"
log "removed $DIR, $SITE and $TMPL"

# Drop the route without disturbing the other apps: reload, never restart.
# Caddy keeps the certificate it issued for the staging name in its shared data
# volume, so the next pull request reuses it instead of asking Let's Encrypt again.
if docker compose ps --services --status running 2>/dev/null | grep -qx caddy; then
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile \
    || log "caddy would not reload — the removed site file is gone from disk, so the next reload drops the route"
  log "caddy reloaded (${APP_SLUG} is no longer routed)"
else
  log "caddy is not running here — nothing to reload"
fi
