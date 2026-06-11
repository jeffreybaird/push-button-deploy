#!/usr/bin/env bash
#
# teardown.sh — destroy everything bootstrap.sh created, in reverse order:
#
#   1. infra-app        droplet, firewall, reserved-IP assignment
#   2. infra-persistent DB CLUSTER (ALL DATA), VPC, reserved IP, tag, DNS record
#   3. registry         the app's image repository (the registry itself stays)
#   4. infra-state      the Terraform state bucket (deleted LAST — it holds the
#                       state of roots 1 and 2 while they are being destroyed)
#
#   ./teardown.sh [--yes] [--delete-repo] [app_dir]
#
#   --yes          skip the type-the-project-name confirmation
#   --delete-repo  also delete the GitHub repo (needs `gh auth refresh -s delete_repo`)
#   app_dir        the app directory (default: .) — used to find the app name
#                  for the registry repository and the GitHub repo
#
# NOT touched: the DO registry itself, the SSH key in DO, the DNSimple zone,
# the local app directory, and (without --delete-repo) the GitHub repo with
# its secrets/variables.
#
# prevent_destroy guards (DB cluster, state bucket) are lifted via Terraform
# override files written for the duration of the destroy and removed after.
#
# Requires the same .env/environment as bootstrap.sh.
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

# ---- helpers (mirror bootstrap.sh) ---------------------------------------------
fail() { printf 'teardown: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '\033[31m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

PERS_DIR="$SCRIPT_DIR/infra-persistent"
APP_TF_DIR="$SCRIPT_DIR/infra-app"
STATE_TF_DIR="$SCRIPT_DIR/infra-state"

REQUIRED_BINS="terraform doctl curl"
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"

# ---- argument parsing ----------------------------------------------------------
ASSUME_YES=0
DELETE_REPO=0
APP_DIR="."
while [ $# -gt 0 ]; do
  case "$1" in
    --yes)         ASSUME_YES=1 ;;
    --delete-repo) DELETE_REPO=1 ;;
    -*)            fail "unknown argument: $1 (use --yes, --delete-repo, [app_dir])" ;;
    *)             APP_DIR="$1" ;;
  esac
  shift
done
if [ -d "$APP_DIR" ]; then APP_DIR="$(cd "$APP_DIR" && pwd)"; fi

# ---- preflight -------------------------------------------------------------------
for b in $REQUIRED_BINS; do have "$b" || fail "missing binary: $b"; done
for v in $REQUIRED_ENV; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || fail "missing env var: $v"
done

# App name (registry repo / GitHub repo) — best effort; skipped if no app found.
APP_NAME=""
if [ -f "$APP_DIR/mix.exs" ]; then
  # shellcheck source=scripts/app-meta.sh
  . "$SCRIPT_DIR/scripts/app-meta.sh"
  APP_NAME="$(app_name "$APP_DIR")"
fi

# PROJECT_NAME: same resolution as bootstrap (env wins, else app-name derived).
if [ -z "${PROJECT_NAME:-}" ]; then
  [ -n "$APP_NAME" ] || fail "PROJECT_NAME not set and no app at $APP_DIR to derive it from"
  PROJECT_NAME="$(printf '%s' "$APP_NAME" | tr '_' '-')"
fi

REGION="${REGION:-nyc3}"
STATE_REGION="${SPACES_REGION:-$REGION}"
STATE_BUCKET="${STATE_BUCKET:-${PROJECT_NAME}-tfstate}"
STATE_ENDPOINT="https://${STATE_REGION}.digitaloceanspaces.com"

export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
export TF_VAR_project_name="$PROJECT_NAME"
export TF_VAR_region="$REGION"
export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
export TF_VAR_dns_zone="$DNS_ZONE"
export TF_VAR_dns_record="${DNS_RECORD:-}"
export TF_VAR_ssh_key_name="${SSH_KEY_NAME:-}"
export TF_VAR_ssh_cidrs='["127.0.0.1/32"]'   # destroy needs the var, not the value
export TF_VAR_state_bucket="$STATE_BUCKET"
export TF_VAR_state_endpoint="$STATE_ENDPOINT"
export TF_VAR_spaces_access_id="$SPACES_ACCESS_KEY_ID"
export TF_VAR_spaces_secret_key="$SPACES_SECRET_ACCESS_KEY"
export TF_VAR_bucket_name="$STATE_BUCKET"

# ---- confirmation ----------------------------------------------------------------
log "TEARDOWN of project '$PROJECT_NAME':"
printf '  - droplet + firewall + reserved-IP assignment\n'
printf '  - DATABASE CLUSTER %s-pg AND ALL ITS DATA\n' "$PROJECT_NAME"
printf '  - VPC, reserved IP, tag, DNS record\n'
if [ -n "$APP_NAME" ]; then printf '  - registry repository %s\n' "$APP_NAME"; fi
printf '  - state bucket %s\n' "$STATE_BUCKET"
if [ "$DELETE_REPO" = 1 ]; then printf '  - GitHub repository (--delete-repo)\n'; fi
if [ "$ASSUME_YES" != 1 ]; then
  printf 'Type the project name (%s) to confirm: ' "$PROJECT_NAME"
  read -r answer
  [ "$answer" = "$PROJECT_NAME" ] || fail "confirmation did not match — aborting (nothing destroyed)"
fi

# ---- backend init (same as bootstrap) ----------------------------------------------
backend_init() {
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  terraform -chdir="$1" init -input=false -force-copy -backend-config=backend.hcl >/dev/null
}

# Lift a prevent_destroy guard for the duration of a destroy. Override files
# merge per-attribute, so only the lifecycle flag changes. Removed via trap.
# Appends, so several guards in the same root share one override file.
OVERRIDES=""
trap 'for f in $OVERRIDES; do rm -f "$f"; done' EXIT
lift_guard() { # $1 dir, $2 resource type, $3 resource name, $4 extra attrs (optional)
  local f="$1/teardown_override.tf"
  # First touch this run: clear any leftover from an earlier crashed run.
  case " $OVERRIDES " in *" $f "*) ;; *) rm -f "$f" ;; esac
  {
    printf 'resource "%s" "%s" {\n' "$2" "$3"
    if [ -n "${4:-}" ]; then printf '  %s\n' "$4"; fi
    printf '  lifecycle { prevent_destroy = false }\n}\n'
  } >> "$f"
  case " $OVERRIDES " in *" $f "*) ;; *) OVERRIDES="$OVERRIDES $f" ;; esac
}

# ---- 1. app infra ------------------------------------------------------------------
log "destroy: infra-app (droplet, firewall)"
backend_init "$APP_TF_DIR"
terraform -chdir="$APP_TF_DIR" destroy -auto-approve -input=false

# ---- 2. persistent infra (THE DATABASE DIES HERE) ----------------------------------
log "destroy: infra-persistent (DB cluster, VPC, reserved IP, DNS)"
backend_init "$PERS_DIR"
lift_guard "$PERS_DIR" digitalocean_database_cluster pg
lift_guard "$PERS_DIR" digitalocean_reserved_ip this
terraform -chdir="$PERS_DIR" destroy -auto-approve -input=false
rm -f "$PERS_DIR/teardown_override.tf"

# ---- 3. registry repository ---------------------------------------------------------
if [ -n "$APP_NAME" ] && doctl registry get --format Name --no-header >/dev/null 2>&1; then
  if doctl registry repository list-v2 --format Name --no-header 2>/dev/null | grep -qx "$APP_NAME"; then
    log "registry: deleting repository '$APP_NAME' (registry itself is kept)"
    doctl registry repository delete "$APP_NAME" --force
    log "registry: space is reclaimed by garbage collection — run when convenient:"
    log "  doctl registry garbage-collection start --include-untagged-manifests --force"
  else
    log "registry: no repository '$APP_NAME' — skipping"
  fi
fi

# ---- 4. state bucket (LAST: it held the state for steps 1-2) -------------------------
log "destroy: infra-state (bucket $STATE_BUCKET)"
terraform -chdir="$STATE_TF_DIR" init -input=false >/dev/null
# force_destroy empties the bucket (incl. old state versions) on delete; it must
# be APPLIED before the destroy so the API call carries the flag.
lift_guard "$STATE_TF_DIR" digitalocean_spaces_bucket tfstate 'force_destroy = true'
terraform -chdir="$STATE_TF_DIR" apply -auto-approve -input=false >/dev/null
terraform -chdir="$STATE_TF_DIR" destroy -auto-approve -input=false
rm -f "$STATE_TF_DIR/teardown_override.tf"

# ---- 5. GitHub repo (opt-in) ----------------------------------------------------------
if [ "$DELETE_REPO" = 1 ]; then
  have gh || fail "gh required for --delete-repo"
  ( cd "$APP_DIR" && gh repo delete --yes ) \
    || fail "gh repo delete failed — it needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo"
fi

# ---- local leftovers -------------------------------------------------------------------
# Drop the backend pointers AND the cached backend configs — a later bootstrap
# with a new project would otherwise try to migrate state out of the (now
# deleted) bucket and die. infra-state's local state is empty post-destroy.
rm -f "$PERS_DIR/backend.hcl" "$APP_TF_DIR/backend.hcl"
rm -rf "$PERS_DIR/.terraform" "$APP_TF_DIR/.terraform" "$STATE_TF_DIR/.terraform"
rm -f "$STATE_TF_DIR/terraform.tfstate" "$STATE_TF_DIR/terraform.tfstate.backup"
log "done. NOT touched: DO registry, DO SSH key, DNSimple zone, local app dir$( [ "$DELETE_REPO" = 1 ] || printf ', GitHub repo (use --delete-repo)' )"
