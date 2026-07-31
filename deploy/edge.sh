#!/usr/bin/env bash
#
# edge.sh — make the droplet ready to host THIS app alongside any others.
# Run by the deploy/rollback workflows over SSH, before the app stack starts:
#
#   APP_SLUG=<slug> DOMAIN=<fqdn> bash /root/caddy/edge.sh
#
# It owns everything shared between apps on the host:
#
#   1. the `edge` docker network every app joins so the shared Caddy can reach it
#   2. the shared Caddy stack in /root/caddy (one per droplet, owns :80/:443)
#   3. this app's site file in /root/caddy/sites/<slug>.caddy, plus the reload
#   4. the ONE-TIME migration of a pre-multi-tenancy droplet (single stack in
#      /root, Caddy inside it) to that layout
#
# Idempotent: every step detects work already done, so it runs on every deploy.
#
# Portable: runs on the droplet (Ubuntu), so bash + GNU coreutils are fine.
set -euo pipefail

cd "$(dirname "$0")"

log()  { printf 'edge: %s\n' "$*"; }
fail() { printf 'edge: %s\n' "$*" >&2; exit 1; }

[ -n "${APP_SLUG:-}" ] || fail "APP_SLUG is required"
[ -n "${DOMAIN:-}" ]   || fail "DOMAIN is required"

LEGACY_COMPOSE=/root/compose.yaml

# ---- 1. the shared network -----------------------------------------------------
# Every app stack declares this network `external`, so it must exist first. It
# outlives all of them on purpose: removing one app must not disconnect the rest.
if ! docker network inspect edge >/dev/null 2>&1; then
  log "creating shared docker network 'edge'"
  docker network create edge >/dev/null
fi

# The Caddy stack bind-mounts this directory at /srv (static sites are served
# straight off it). Docker would create it as a directory anyway, but only after
# the compose file references it — make it exist first so the mount is never a
# surprise root-owned path created by the daemon.
mkdir -p /root/apps

# ---- 2. one-time migration off the single-app layout ---------------------------
# Before multi-tenancy the app stack lived in /root and carried its own Caddy.
# That layout can host exactly one app: the compose project is named for the
# directory (root), so a second app would collide on service names, volume names
# and port 443.
#
# The migration is done by the app that is ALREADY on the droplet, during its
# own deploy — it is the only deploy that knows which data belongs to it. A
# different app arriving first would copy the wrong data into its own volume, so
# compare the legacy stack's domain with ours and refuse if they differ.
if [ -f "$LEGACY_COMPOSE" ]; then
  legacy_domain="$(sed -n 's/^DOMAIN=//p' /root/.env 2>/dev/null | head -1 || true)"
  if [ "$legacy_domain" != "$DOMAIN" ]; then
    # Includes the case where /root/.env is missing or has no DOMAIN: without it
    # there is no way to tell whose data the old volume holds, and guessing wrong
    # would copy another app's database into this one.
    fail "this droplet still runs the single-app layout${legacy_domain:+ for '$legacy_domain'}, and '$DOMAIN' is not it.
     Deploy ${legacy_domain:-the app already on this droplet} once first — that deploy migrates the
     droplet to the shared-Caddy layout — then re-run this one."
  fi

  log "migrating droplet off the single-app layout (brief downtime until the swap)"

  # Stop the old project — app colors AND the Caddy that lived inside it, which
  # is what frees :80/:443 for the shared stack. No -v: the named volumes
  # (root_app_data, root_caddy_data, root_caddy_config) must survive.
  docker compose -f "$LEGACY_COMPOSE" -p root down --remove-orphans || true

  # The SQLite database moves with the app: the old volume was named for the old
  # project (root_app_data), the new stack will look for <slug>_app_data. Copy
  # rather than rename — a rename has no docker primitive, and a copy leaves the
  # original in place as a rollback.
  #
  # Litestream would eventually restore this from Spaces, but only writes that
  # made it off-box: copying the volume keeps the last few seconds too.
  if docker volume inspect root_app_data >/dev/null 2>&1; then
    new_vol="${APP_SLUG}_app_data"
    if [ -z "$(docker run --rm -v "$new_vol":/to alpine:3.22 sh -c 'ls -A /to' 2>/dev/null)" ]; then
      log "copying SQLite volume root_app_data -> $new_vol"
      docker run --rm -v root_app_data:/from -v "$new_vol":/to alpine:3.22 \
        sh -c 'cp -a /from/. /to/'
    else
      log "$new_vol already has data — leaving it alone"
    fi
  fi

  # Park the legacy files instead of deleting them: if the migration goes wrong
  # the old stack is one `docker compose -f /root/legacy/compose.yaml -p root up`
  # away. .env is NOT moved — the new stack writes its own, and the old one is a
  # secret-bearing file we would rather not multiply.
  mkdir -p /root/legacy
  for f in compose.yaml Caddyfile swap.sh litestream.yml db-ca.pem; do
    [ -e "/root/$f" ] && mv "/root/$f" /root/legacy/
  done
  log "legacy stack files parked in /root/legacy"
fi

# ---- 3. the shared Caddy stack --------------------------------------------------
mkdir -p sites

# This app's site file. Written every deploy so a domain change lands, and
# compared first so an unchanged deploy doesn't churn the config.
site="sites/${APP_SLUG}.caddy"
tmp="$(mktemp)"
sed -e "s|__DOMAIN__|${DOMAIN}|g" -e "s|__SLUG__|${APP_SLUG}|g" site.caddy.tmpl > "$tmp"
if ! cmp -s "$tmp" "$site"; then
  mv "$tmp" "$site"
  log "wrote $site ($DOMAIN -> ${APP_SLUG}-blue/green:4000)"
else
  rm -f "$tmp"
fi

# Start (or adopt) the shared Caddy. compose.yaml pins the project name, so this
# is the same project the legacy stack's Caddy volumes belong to — the certs
# already issued for other apps on this droplet are reused, not re-requested.
docker compose up -d caddy

# Reload rather than restart: a restart drops in-flight requests for every OTHER
# app on the droplet, and this app's own colors aren't up yet anyway. A config
# Caddy rejects fails the command, and therefore the deploy — the running config
# keeps serving.
#
# The retry covers a container that was just created and hasn't opened its admin
# socket yet.
for i in 1 2 3 4 5; do
  if docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile; then
    log "caddy reloaded ($DOMAIN is routed)"
    exit 0
  fi
  log "  caddy not ready for reload yet (attempt $i/5)"
  sleep 2
done
fail "caddy would not accept the reloaded config — the previous config is still serving"
