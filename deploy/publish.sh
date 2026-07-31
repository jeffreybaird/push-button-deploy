#!/usr/bin/env bash
#
# publish.sh — point a static site at a release, atomically.
# Run by the deploy/rollback workflows over SSH, from the site's stack directory:
#
#   bash /root/apps/<slug>/publish.sh <release-id>
#
# This is the static-site counterpart to swap.sh. There is no blue/green pair to
# swap because there are no app containers: the shared Caddy serves files from
# `current`, a symlink into releases/. Moving that symlink IS the deploy, and
# because Caddy resolves the root per request it takes effect immediately, with
# no reload and no dropped requests.
#
# Rollback is the same operation with an older release id — nothing is rebuilt
# and nothing is re-uploaded, which is why old releases are kept around.
#
# Portable: runs on the droplet (Ubuntu), so GNU coreutils are assumed.
set -euo pipefail

cd "$(dirname "$0")"

log()  { printf 'publish: %s\n' "$*"; }
fail() { printf 'publish: %s\n' "$*" >&2; exit 1; }

REL="${1:-}"
[ -n "$REL" ] || fail "usage: publish.sh <release-id>"

# How many releases to keep. Each is a full copy of the built site, so this is
# both the rollback window and the disk budget.
KEEP="${KEEP_RELEASES:-5}"

[ -d "releases/$REL" ] || fail "no such release: releases/$REL
     available: $(ls -1 releases 2>/dev/null | tr '\n' ' ')"

# A release that built to nothing would serve a directory listing (or 404
# everything) rather than fail — catch it before it goes live, not after.
[ -f "releases/$REL/index.html" ] \
  || fail "releases/$REL has no index.html — refusing to publish an empty build"

# Atomic: a single rename(2) over the existing symlink.
#
# `ln -sfn current` is NOT atomic — it unlinks and recreates, so a request
# landing in that window sees no root at all. `mv -T` would do the right thing
# but is a GNU extension (BSD mv follows the symlink and moves INTO the
# directory), so this calls rename(2) directly through perl: same syscall, no
# shell subtleties, and it behaves identically wherever it runs.
#
# The target is RELATIVE so the link resolves identically inside the Caddy
# container, which sees this directory as /srv/<slug>.
rm -f current.tmp
ln -s "releases/$REL" current.tmp
perl -e 'rename($ARGV[0], $ARGV[1]) or die "rename: $!\n"' current.tmp current
log "current -> releases/$REL"

# Prune oldest-first, and never the release now serving. Guarding on the
# resolved target rather than on $REL also protects a release that is current
# under a different name (a rollback republishes an old id).
live="$(readlink current)"
n=0
for d in $(ls -1dt releases/*/ 2>/dev/null); do
  d="${d%/}"
  [ "$d" = "$live" ] && continue
  n=$((n + 1))
  if [ "$n" -ge "$KEEP" ]; then
    log "pruning $d"
    rm -rf "$d"
  fi
done
