#!/usr/bin/env bash
#
# bootstrap.sh — push-button stand-up for a Phoenix app on DigitalOcean.
#
#   ./bootstrap.sh --check          # story 6.1: verify prerequisites, exit non-zero on first gap
#   ./bootstrap.sh                   # story 6.2: provision + wire + first deploy   (added next)
#
# Required environment (the deploy's single source of truth):
#   DIGITALOCEAN_ACCESS_TOKEN   DO API token (terraform, doctl, DOCR, gh secret)
#   DNSIMPLE_TOKEN              DNSimple API token (terraform)
#   DNSIMPLE_ACCOUNT           DNSimple account id (terraform)
#   DNS_ZONE                   apex zone, e.g. lennonbaird.com
#   SSH_KEY_NAME               name of an SSH key already uploaded to DO
#   SSH_PRIVATE_KEY            path to the matching private key (becomes a gh secret)
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

# ---- helpers -----------------------------------------------------------------
fail() { printf 'preflight: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

REQUIRED_BINS="git terraform doctl gh mix curl ssh scp"
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY"

# ---- story 6.1: preflight ----------------------------------------------------
# Checks run in order and fail fast, naming the FIRST gap (AC 6.1).
preflight() {
  local b v val

  for b in $REQUIRED_BINS; do
    have "$b" || fail "missing binary: $b"
  done

  # phx_new archive (needed to generate the app in 6.2).
  mix phx.new --version >/dev/null 2>&1 \
    || fail "phx_new archive missing — run: mix archive.install hex phx_new"

  for v in $REQUIRED_ENV; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || fail "missing env var: $v"
  done

  [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"

  doctl account get >/dev/null 2>&1 \
    || fail "doctl not authenticated — run: doctl auth init"

  gh auth status >/dev/null 2>&1 \
    || fail "gh not authenticated — run: gh auth login"

  # The SSH key the droplet will trust must already exist in the DO account.
  doctl compute ssh-key list --no-header --format Name 2>/dev/null \
    | grep -qx "$SSH_KEY_NAME" \
    || fail "SSH key '$SSH_KEY_NAME' not found in DO account (doctl compute ssh-key list)"

  echo "preflight: OK — all prerequisites present."
}

# ---- main --------------------------------------------------------------------
main() {
  case "${1:-}" in
    --check)
      preflight
      ;;
    "")
      preflight
      fail "full provisioning not implemented yet (story 6.2). Use --check for now."
      ;;
    *)
      fail "unknown argument: $1 (use --check)"
      ;;
  esac
}

main "$@"
