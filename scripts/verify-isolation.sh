#!/usr/bin/env bash
#
# verify-isolation.sh — assert that destroying infra-app touches ONLY the
# droplet, its firewall, and the reserved-IP binding. The managed Postgres
# cluster and the reserved IP itself must survive (they live in infra-persistent
# state, are guarded by prevent_destroy, and are referenced here read-only).
#
# Runs `terraform plan -destroy` in the app module and fails if the plan would
# destroy anything outside the allowlist. Requires DO creds + applied state.
#
# Usage: scripts/verify-isolation.sh [infra-app-dir]
#
# Portable: POSIX-ish bash, works with BSD (macOS) grep/sed.
set -euo pipefail

APP_DIR="${1:-infra-app}"

# Resource-address prefixes infra-app is permitted to destroy.
ALLOWED='^(digitalocean_droplet|digitalocean_firewall|digitalocean_reserved_ip_assignment)\.'

command -v terraform >/dev/null 2>&1 || { echo "Error: terraform not found." >&2; exit 1; }
[ -d "$APP_DIR" ] || { echo "Error: app dir not found: $APP_DIR" >&2; exit 1; }

echo "==> terraform plan -destroy in $APP_DIR"
plan="$(terraform -chdir="$APP_DIR" plan -destroy -no-color)"

# Pull every "# <address> will be destroyed" line into a list of addresses.
destroyed="$(printf '%s\n' "$plan" \
  | grep -E '# .* will be destroyed' \
  | sed -E 's/.*# ([^ ]+) will be destroyed.*/\1/' \
  || true)"

if [ -z "$destroyed" ]; then
  echo "Nothing to destroy (no applied droplet?). Nothing to verify."
  exit 0
fi

echo "Resources the destroy would remove:"
printf '  %s\n' $destroyed

violations=""
for addr in $destroyed; do
  if ! printf '%s' "$addr" | grep -Eq "$ALLOWED"; then
    violations="$violations $addr"
  fi
done

if [ -n "$violations" ]; then
  echo >&2
  echo "FAIL: destroy would remove resources OUTSIDE the allowlist:" >&2
  printf '  %s\n' $violations >&2
  echo "Lifecycle isolation is broken — the DB or reserved IP would be affected." >&2
  exit 1
fi

echo
echo "OK: destroy is limited to droplet + firewall + reserved-IP binding."
echo "DB cluster and reserved IP are untouched."
