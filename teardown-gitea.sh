#!/usr/bin/env bash
#
# teardown-gitea.sh — destroy everything bootstrap-gitea.sh created:
#
#   the droplet, its firewall, the reserved IP, the DNS record, and the DATA
#   VOLUME (every git repo, the Gitea DB, Actions logs — ALL OF IT).
#
#   ./teardown-gitea.sh [--yes]
#
#   --yes   skip the type-the-project-name confirmation
#
# NOT touched: the Gitea state bucket (left alone the same way the app
# teardown leaves the DO registry alone — delete it by hand if you're really
# done: doctl spaces ... or via the DO console).
#
# This does NOT touch any app deployed through this Gitea instance, or any
# app droplet's firewall allow-list entry for this instance's IP (that entry
# lives in the APP's own infra-app state and is harmless left stale).
#
# Requires the same .env as bootstrap-gitea.sh.
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

set -E
trap 'printf "\033[31mteardown-gitea: unexpected failure at line %s (running: %s)\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

fail() { printf 'teardown-gitea: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '\033[31m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same .env precedence rule as the other scripts: the calling shell wins.
if [ -f "$SCRIPT_DIR/.env" ]; then
  _envtmp="$(mktemp)"
  for _k in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SCRIPT_DIR/.env"); do
    if [ -n "${!_k+x}" ]; then printf '%s=%q\n' "$_k" "${!_k}" >> "$_envtmp"; fi
  done
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
  if [ -s "$_envtmp" ]; then
    while IFS= read -r _line; do
      _k="${_line%%=*}"
      _was="${!_k}"
      eval "export $_line"
      [ "$_was" != "${!_k}" ] && log "$_k: using '${!_k}' from the environment, not '$_was' from .env"
    done < "$_envtmp"
  fi
  rm -f "$_envtmp"
  unset _envtmp _k _line _was
fi

GITEA_PROJECT_NAME="${GITEA_PROJECT_NAME:-gitea-infra}"
GITEA_REGION="${GITEA_REGION:-nyc3}"
# Same isolation reasoning as bootstrap-gitea.sh: never honor an app's own
# STATE_BUCKET override from this shared .env.
STATE_BUCKET="${GITEA_STATE_BUCKET:-${GITEA_PROJECT_NAME}-tfstate}"
STATE_REGION="${GITEA_SPACES_REGION:-$GITEA_REGION}"
STATE_ENDPOINT="https://${STATE_REGION}.digitaloceanspaces.com"

REQUIRED_BINS="terraform doctl"
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE"
for b in $REQUIRED_BINS; do have "$b" || fail "missing binary: $b"; done
for v in $REQUIRED_ENV; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || fail "missing env var: $v"
done

ASSUME_YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    *)     fail "unknown argument: $1 (use --yes)" ;;
  esac
  shift
done

GITEA_TF_DIR="$SCRIPT_DIR/infra-gitea"
STATE_TF_DIR="$SCRIPT_DIR/infra-state"

export AWS_ACCESS_KEY_ID="${SPACES_ACCESS_KEY_ID:-}"
export AWS_SECRET_ACCESS_KEY="${SPACES_SECRET_ACCESS_KEY:-}"
export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
export TF_VAR_project_name="$GITEA_PROJECT_NAME"
export TF_VAR_region="$GITEA_REGION"
export TF_VAR_droplet_size="${GITEA_DROPLET_SIZE:-s-2vcpu-4gb}"
export TF_VAR_data_volume_gb="${GITEA_DATA_VOLUME_GB:-40}"
export TF_VAR_ssh_key_name="${SSH_KEY_NAME:-}"
export TF_VAR_ssh_cidrs='["127.0.0.1/32"]' # destroy needs the var, not the value
export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
export TF_VAR_dns_zone="$DNS_ZONE"
export TF_VAR_dns_record="${GITEA_DNS_RECORD:-git}"

log "TEARDOWN of Gitea ('$GITEA_PROJECT_NAME'):"
printf '  - the droplet, its firewall, the reserved IP\n'
printf '  - the DNS record\n'
printf '  - the DATA VOLUME — EVERY GIT REPO, THE GITEA DB, ACTIONS LOGS. ALL OF IT.\n'
printf '  NOT touched: the state bucket (%s), any app deployed through this instance.\n' "$STATE_BUCKET"
if [ "$ASSUME_YES" != 1 ]; then
  printf 'Type the project name (%s) to confirm: ' "$GITEA_PROJECT_NAME"
  read -r answer
  [ "$answer" = "$GITEA_PROJECT_NAME" ] || fail "confirmation did not match — aborting (nothing destroyed)"
fi

cat > "$GITEA_TF_DIR/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
terraform -chdir="$GITEA_TF_DIR" init -input=false -force-copy -backend-config=backend.hcl >/dev/null \
  || fail "terraform init failed — is the state bucket '$STATE_BUCKET' still there? (nothing destroyed yet)"

# Lift the two prevent_destroy guards for the duration of this destroy —
# removed via trap regardless of outcome, which also stamps a clear
# FAILED/OK banner (same shape as teardown.sh's) rather than a silent exit.
OVERRIDE="$GITEA_TF_DIR/teardown_override.tf"
trap 'rc=$?; rm -f "'"$OVERRIDE"'"
      [ "$rc" -ne 0 ] && printf "\033[31m==> teardown-gitea FAILED (exit %s) — fix and re-run; already-destroyed resources are skipped\033[0m\n" "$rc" >&2
      exit "$rc"' EXIT
cat > "$OVERRIDE" <<'EOF'
resource "digitalocean_reserved_ip" "gitea" {
  lifecycle { prevent_destroy = false }
}
resource "digitalocean_volume" "gitea_data" {
  lifecycle { prevent_destroy = false }
}
EOF

log "destroy: infra-gitea (droplet, firewall, reserved IP, DNS record, DATA VOLUME)"
terraform -chdir="$GITEA_TF_DIR" destroy -auto-approve -input=false
rm -f "$OVERRIDE" "$GITEA_TF_DIR/backend.hcl"
rm -rf "$GITEA_TF_DIR/.terraform"

log "done. NOT touched: state bucket ($STATE_BUCKET) — delete it by hand if you're really done."
