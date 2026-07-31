#!/usr/bin/env bash
#
# teardown.sh — destroy everything bootstrap.sh created, in reverse order:
#
#   1. infra/app        droplet, firewall, reserved-IP assignment
#   2. infra/persistent DB CLUSTER (ALL DATA), VPC, reserved IP, tag, DNS record
#   3. registry         the app's image repository (the registry itself stays)
#   4. infra/state      the Terraform state bucket (deleted LAST — it holds the
#                       state of roots 1 and 2 while they are being destroyed)
#
#   ./teardown.sh [--yes] [--delete-repo] [app_dir]
#
#   --yes          skip the type-the-project-name confirmation
#   --delete-repo  also delete the GitHub repo (needs `gh auth refresh -s delete_repo`)
#   app_dir        the app directory (default: .) — holds the app's own Terraform
#                  roots under infra/, and names the registry/GitHub repo
#
# The roots destroyed are the APP'S copies (<app_dir>/infra/), the same ones
# bootstrap.sh applied. Apps bootstrapped before infra/ existed fall back to
# this repo's infra-* directories.
#
# TENANT APPS (those with an infra/tenant/ root — apps deployed onto a droplet
# another app owns) take a different, much smaller path: their DNS record, their
# stack + volumes under /root/apps/<slug> on the droplet, and their route out of
# the shared Caddy. The droplet, its other apps, the reserved IP and the state
# bucket belong to the host and are never touched.
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

# Never die silently: name the failing line/command, and stamp failed exits.
set -E
trap 'printf "\033[31mteardown: unexpected failure at line %s (running: %s)\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR

# ---- helpers (mirror bootstrap.sh) ---------------------------------------------
fail() { printf 'teardown: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '\033[31m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same precedence rule as bootstrap.sh: the CALLING SHELL WINS. A teardown that
# silently used .env's DNS_ZONE instead of the one the operator named would
# destroy records in the wrong zone.
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

# Destroy the app's OWN Terraform roots — the ones bootstrap.sh applied, which
# may carry local edits. Apps predating <app_dir>/infra/ still have their roots
# only in this repo, so fall back to those.
# A TENANT app has exactly one root and owns no shared infrastructure: it runs
# on a droplet another app provisioned. Tearing it down must therefore remove
# its DNS record, its stack + volumes on the droplet and its route through the
# shared Caddy — and touch nothing else. The full teardown below would try to
# destroy a droplet, a database and a bucket this app never owned.
TENANT=0
TENANT_TF_DIR="$APP_DIR/infra/tenant"
if [ -d "$TENANT_TF_DIR" ]; then
  TENANT=1
  REQUIRED_ENV="$REQUIRED_ENV SSH_PRIVATE_KEY"
  log "using the app's tenant root: $TENANT_TF_DIR (this app shares another app's droplet)"
elif [ -d "$APP_DIR/infra/state" ]; then
  PERS_DIR="$APP_DIR/infra/persistent"
  APP_TF_DIR="$APP_DIR/infra/app"
  STATE_TF_DIR="$APP_DIR/infra/state"
  log "using the app's Terraform roots: $APP_DIR/infra"
else
  PERS_DIR="$SCRIPT_DIR/infra-persistent"
  APP_TF_DIR="$SCRIPT_DIR/infra-app"
  STATE_TF_DIR="$SCRIPT_DIR/infra-state"
  log "no $APP_DIR/infra — falling back to this repo's Terraform roots"
fi

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
elif [ -f "$APP_DIR/Gemfile" ] || [ -f "$APP_DIR/config.toml" ]; then
  # Sinatra apps and Zola sites have no mix.exs; the name is the directory
  # basename (the same rule bootstrap's parse_meta uses).
  APP_NAME="$(basename "$APP_DIR")"
fi

# A static site (Zola) pushes no image, so there is no registry repository to
# delete — and deleting one that happens to share its name would take another
# app's images with it.
STATIC=0
if [ -f "$APP_DIR/config.toml" ] && [ ! -f "$APP_DIR/mix.exs" ] && [ ! -f "$APP_DIR/Gemfile" ]; then
  STATIC=1
fi

# PROJECT_NAME: same resolution as bootstrap (env wins, else app-name derived).
if [ -z "${PROJECT_NAME:-}" ]; then
  [ -n "$APP_NAME" ] || fail "PROJECT_NAME not set and no app at $APP_DIR to derive it from"
  PROJECT_NAME="$(printf '%s' "$APP_NAME" | tr '_' '-')"
fi

# ---- tenant teardown (self-contained; exits) --------------------------------------
if [ "$TENANT" = 1 ]; then
  have ssh || fail "missing binary: ssh (a tenant teardown removes its stack from the shared droplet)"
  [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"

  # The tenant root records where its state lives; it is the HOST's bucket, so
  # nothing here may create or destroy a bucket.
  hcl="$TENANT_TF_DIR/backend.hcl"
  [ -f "$hcl" ] || fail "no $hcl — run the bootstrap on this app once before tearing it down"
  STATE_BUCKET="$(sed -nE 's/^bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  STATE_ENDPOINT="$(sed -nE 's/.*s3[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  STATE_KEY="$(sed -nE 's/^key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  [ -n "$STATE_BUCKET" ] && [ -n "$STATE_ENDPOINT" ] && [ -n "$STATE_KEY" ] \
    || fail "could not read bucket/endpoint/key from $hcl"

  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
  export TF_VAR_project_name="$PROJECT_NAME"
  export TF_VAR_state_bucket="$STATE_BUCKET"
  export TF_VAR_state_endpoint="$STATE_ENDPOINT"
  export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
  export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
  export TF_VAR_dns_zone="$DNS_ZONE"
  export TF_VAR_dns_record="${DNS_RECORD:-$PROJECT_NAME}"

  terraform -chdir="$TENANT_TF_DIR" init -input=false -force-copy -backend-config=backend.hcl >/dev/null

  # Read the droplet's address BEFORE destroying the record that documents it.
  DROPLET_IP="$(terraform -chdir="$TENANT_TF_DIR" output -raw host_ip 2>/dev/null || true)"
  SLUG="$PROJECT_NAME"

  log "TEARDOWN of TENANT '$PROJECT_NAME' (shared droplet ${DROPLET_IP:-unknown}):"
  printf '  - DNS record for this app\n'
  if [ "$STATIC" = 1 ]; then
    printf '  - /root/apps/%s on the droplet (its built releases)\n' "$SLUG"
  else
    printf '  - /root/apps/%s on the droplet, INCLUDING ITS SQLITE VOLUME (all data)\n' "$SLUG"
  fi
  printf '  - its route from the shared Caddy (/root/caddy/sites/%s.caddy)\n' "$SLUG"
  if [ -n "$APP_NAME" ] && [ "$STATIC" != 1 ]; then printf '  - registry repository %s\n' "$APP_NAME"; fi
  if [ "$DELETE_REPO" = 1 ]; then printf '  - GitHub repository (--delete-repo)\n'; fi
  printf '  NOT touched: the droplet, its other apps, the reserved IP, the state bucket.\n'
  [ "$STATIC" = 1 ] \
    || printf '  NOT touched: this app%s Litestream replica in Spaces (litestream/%s/) — delete it by hand if you want the data gone.\n' "'s" "$PROJECT_NAME"
  if [ "$ASSUME_YES" != 1 ]; then
    printf 'Type the project name (%s) to confirm: ' "$PROJECT_NAME"
    read -r answer
    [ "$answer" = "$PROJECT_NAME" ] || fail "confirmation did not match — aborting (nothing destroyed)"
  fi

  # 1. Remove the stack from the droplet. -v takes this app's volumes (its
  #    SQLite file); they are project-scoped, so no other app's data is in
  #    reach. Best-effort: a droplet we cannot reach (firewall, already gone)
  #    must not block destroying the DNS record.
  if [ -n "$DROPLET_IP" ]; then
    log "droplet: removing /root/apps/$SLUG and its volumes"
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
      root@"$DROPLET_IP" "
        set -e
        # A static site has no compose file; the -f guard keeps this from
        # erroring out before the rm below gets to run.
        if [ -f /root/apps/$SLUG/compose.yaml ]; then cd /root/apps/$SLUG && docker compose down -v --remove-orphans || true; fi
        rm -rf /root/apps/$SLUG /root/caddy/sites/$SLUG.caddy
        # Drop this app's route without disturbing the other apps' traffic.
        cd /root/caddy && docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
      " || log "WARNING: could not clean the droplet (unreachable?) — remove /root/apps/$SLUG and /root/caddy/sites/$SLUG.caddy by hand"
  else
    log "WARNING: no host IP in state — skipping droplet cleanup; remove /root/apps/$SLUG by hand"
  fi

  # 2. The one piece of infrastructure this app owns.
  log "destroy: infra/tenant (DNS record)"
  terraform -chdir="$TENANT_TF_DIR" destroy -auto-approve -input=false

  # 3. Registry repository (the registry itself is shared and stays).
  if [ -n "$APP_NAME" ] && [ "$STATIC" != 1 ] && doctl registry get --format Name --no-header >/dev/null 2>&1; then
    if doctl registry repository list-v2 --format Name --no-header 2>/dev/null | grep -qx "$APP_NAME"; then
      log "registry: deleting repository '$APP_NAME' (registry itself is kept)"
      doctl registry repository delete "$APP_NAME" --force
    fi
  fi

  if [ "$DELETE_REPO" = 1 ]; then
    have gh || fail "gh required for --delete-repo"
    ( cd "$APP_DIR" && gh repo delete --yes ) \
      || fail "gh repo delete failed — it needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo"
  fi

  # The bucket belongs to the host and stays; so does this tenant's now-empty
  # state object under tenants/<project>/ (a few hundred bytes, and deleting it
  # would mean reaching into the host's bucket by hand).
  rm -rf "$TENANT_TF_DIR/.terraform"
  log "done. The droplet and its other apps are untouched."
  exit 0
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
trap 'rc=$?; for f in $OVERRIDES; do rm -f "$f"; done
      [ "$rc" -ne 0 ] && printf "\033[31m==> teardown FAILED (exit %s) — fix and re-run; already-destroyed resources are skipped\033[0m\n" "$rc" >&2
      exit "$rc"' EXIT
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
# infra-state keeps per-project LOCAL state in workspaces (see bootstrap).
terraform -chdir="$STATE_TF_DIR" workspace select -or-create "$PROJECT_NAME" >/dev/null
# Adopt the bucket if this workspace's state doesn't know it (half-run, or the
# bucket was created by bootstrap's direct-API fallback) — destroy on an empty
# state would otherwise silently leave the bucket alive.
if ! terraform -chdir="$STATE_TF_DIR" state list 2>/dev/null | grep -q .; then
  log "importing bucket '$STATE_BUCKET' into state before destroy"
  terraform -chdir="$STATE_TF_DIR" import -input=false \
    digitalocean_spaces_bucket.tfstate "${STATE_REGION},${STATE_BUCKET}" >/dev/null \
    || fail "bucket '$STATE_BUCKET' could not be imported — if it does not exist, nothing to do; remove it from the plan by re-running without the state step"
fi
# force_destroy empties the bucket (incl. old state versions) on delete; it must
# be APPLIED before the destroy so the API call carries the flag.
lift_guard "$STATE_TF_DIR" digitalocean_spaces_bucket tfstate 'force_destroy = true'
terraform -chdir="$STATE_TF_DIR" apply -auto-approve -input=false >/dev/null
terraform -chdir="$STATE_TF_DIR" destroy -auto-approve -input=false
rm -f "$STATE_TF_DIR/teardown_override.tf"
# drop the emptied workspace
terraform -chdir="$STATE_TF_DIR" workspace select default >/dev/null 2>&1 || true
terraform -chdir="$STATE_TF_DIR" workspace delete "$PROJECT_NAME" >/dev/null 2>&1 || true

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
