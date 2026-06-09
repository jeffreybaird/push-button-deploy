#!/usr/bin/env bash
#
# bootstrap.sh — push-button stand-up for a Phoenix app on DigitalOcean.
#
#   ./bootstrap.sh --check [app_dir]   # verify prerequisites, exit non-zero on first gap
#   ./bootstrap.sh [app_dir]           # provision + wire + deploy (default app_dir: .)
#
# app_dir may be EMPTY or NOT EXIST YET: a fresh Phoenix app is generated there
# (mix phx.new <basename>). An existing app is used as-is.
#
# Optional config (env, with defaults):
#   PROJECT_NAME   infra naming (DB/tag/VPC). Default: the app name. IMMUTABLE after first apply.
#   REGION         DO region slug. Default: nyc3.
#   DNS_RECORD     subdomain in DNS_ZONE. Default: the app name.
#   SSH_CIDRS      JSON list for SSH allow, e.g. ["1.2.3.4/32"]. Default: auto-detected public IP /32.
#   DOCR_REGISTRY  name for a new DO registry if none exists. Default: PROJECT_NAME.
#   STATE_BUCKET   Spaces bucket for Terraform state. Default: <PROJECT_NAME>-tfstate.
#   SPACES_REGION  region for the state bucket (must offer Spaces). Default: REGION.
#
# Idempotent: safe to re-run after fixing a gap — every step guards re-entry.
#
# Required environment (the deploy's single source of truth) — export in the
# shell OR put in a gitignored .env beside this script (auto-sourced, see
# .env.example):
#   DIGITALOCEAN_ACCESS_TOKEN   DO API token (terraform, doctl, DOCR, gh secret)
#   DNSIMPLE_TOKEN              DNSimple API token (terraform)
#   DNSIMPLE_ACCOUNT           DNSimple account id (terraform)
#   DNS_ZONE                   apex zone, e.g. lennonbaird.com
#   SSH_KEY_NAME               name of an SSH key already uploaded to DO
#   SSH_PRIVATE_KEY            path to the matching private key (becomes a gh secret)
#   SPACES_ACCESS_KEY_ID       Spaces access key (Terraform state bucket, story 7.4)
#   SPACES_SECRET_ACCESS_KEY   Spaces secret key
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

# ---- helpers -----------------------------------------------------------------
fail() { printf 'bootstrap: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local config: a gitignored .env beside this script (see .env.example).
# Shell-sourced, so $HOME etc. expand; `set -a` exports plain KEY=value lines
# (an `export ` prefix also works). File values override the calling shell's.
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a
fi

PERS_DIR="$SCRIPT_DIR/infra-persistent"
APP_TF_DIR="$SCRIPT_DIR/infra-app"
STATE_TF_DIR="$SCRIPT_DIR/infra-state"

REQUIRED_BINS="git terraform doctl gh mix curl ssh scp dig"
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"

# ---- story 6.1: preflight ----------------------------------------------------
# Checks run in order and fail fast, naming the FIRST gap (AC 6.1).
preflight() {
  local b v val

  for b in $REQUIRED_BINS; do
    have "$b" || fail "missing binary: $b"
  done

  # Bootstrap injects ALL terraform variables via TF_VAR_ env, which tfvars
  # files silently OVERRIDE (terraform precedence: tfvars > env). A leftover
  # tfvars file means stale tokens/CIDRs/names win — fail loudly instead.
  local dir f
  for dir in "$PERS_DIR" "$APP_TF_DIR" "$STATE_TF_DIR"; do
    for f in "$dir"/terraform.tfvars "$dir"/terraform.tfvars.json "$dir"/*.auto.tfvars "$dir"/*.auto.tfvars.json; do
      [ -e "$f" ] && fail "$f would override bootstrap's variables (terraform precedence: tfvars beats TF_VAR_ env). Move it aside: mv '$f' '$f.bak'"
    done
  done

  for v in $REQUIRED_ENV; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || fail "missing env var: $v"
  done

  [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"

  # Generating the app (only when the target has none) needs the phx_new archive.
  if [ ! -f "$APP_DIR/mix.exs" ]; then
    mix phx.new --version >/dev/null 2>&1 \
      || fail "no app at $APP_DIR, and the phx_new archive is missing — run: mix archive.install hex phx_new"
  fi

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

# ---- story 6.2: provision + wire + first deploy ------------------------------

# Generate the Phoenix app when the target directory is empty or missing —
# this is the "empty directory -> deployed app" entry point. An existing app
# (e.g. from a custom generator) is used as-is; a non-empty non-app directory
# is refused rather than generated over.
ensure_app() {
  if [ -f "$APP_DIR/mix.exs" ]; then
    log "app: using existing $APP_DIR"
    return 0
  fi
  if [ -d "$APP_DIR" ]; then
    [ -z "$(ls -A "$APP_DIR")" ] \
      || fail "$APP_DIR is not empty and has no mix.exs — refusing to generate over it"
    # phx.new insists on creating the directory itself (prompts otherwise).
    rmdir "$APP_DIR"
  fi
  local name parent
  name="$(basename "$APP_DIR")"
  parent="$(dirname "$APP_DIR")"
  log "generating Phoenix app '$name' (mix phx.new --no-install)"
  ( cd "$parent" && mix phx.new "$name" --no-install )
}

# Parse APP_NAME / APP_MODULE from the app's mix.exs (single source of truth).
parse_meta() {
  [ -f "$APP_DIR/mix.exs" ] || fail "no mix.exs in $APP_DIR — generation failed?"
  # shellcheck source=scripts/app-meta.sh
  . "$SCRIPT_DIR/scripts/app-meta.sh"
  APP_NAME="$(app_name "$APP_DIR")"
  APP_MODULE="$(app_module "$APP_DIR")"
  PROJECT_NAME="${PROJECT_NAME:-$APP_NAME}"
  REGION="${REGION:-nyc3}"
  DNS_RECORD="${DNS_RECORD:-$APP_NAME}"
  log "app: $APP_NAME ($APP_MODULE) | project: $PROJECT_NAME | region: $REGION"
}

# Ensure the Spaces state bucket exists (story 7.4). This tiny root keeps
# LOCAL state on purpose — the bucket can't store the state that creates it.
ensure_state_bucket() {
  # The s3 backend + remote_state reads authenticate with the AWS env names.
  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"

  STATE_REGION="${SPACES_REGION:-$REGION}"
  STATE_BUCKET="${STATE_BUCKET:-${PROJECT_NAME}-tfstate}"
  STATE_ENDPOINT="https://${STATE_REGION}.digitaloceanspaces.com"

  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_spaces_access_id="$SPACES_ACCESS_KEY_ID"
  export TF_VAR_spaces_secret_key="$SPACES_SECRET_ACCESS_KEY"
  export TF_VAR_bucket_name="$STATE_BUCKET"
  export TF_VAR_region="$STATE_REGION"

  log "terraform: infra-state (Spaces bucket '$STATE_BUCKET' in $STATE_REGION)"
  terraform -chdir="$STATE_TF_DIR" init -input=false >/dev/null
  terraform -chdir="$STATE_TF_DIR" apply -auto-approve -input=false
}

# Point a root at the Spaces backend and init. -force-copy migrates any
# existing local state into the bucket on first contact (idempotent after).
backend_init() {
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  terraform -chdir="$1" init -input=false -force-copy -backend-config=backend.hcl >/dev/null
}

# Provision persistent infra. Guards project_name immutability against TF state.
tf_persistent() {
  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_project_name="$PROJECT_NAME"
  export TF_VAR_region="$REGION"
  export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
  export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
  export TF_VAR_dns_zone="$DNS_ZONE"
  export TF_VAR_dns_record="$DNS_RECORD"

  log "terraform: infra-persistent"
  backend_init "$PERS_DIR"

  # project_name is immutable: renaming forces DB-cluster replacement (blocked by
  # prevent_destroy). Compare against state and fail loud before applying.
  if terraform -chdir="$PERS_DIR" output -raw project_name >/dev/null 2>&1; then
    local existing; existing="$(terraform -chdir="$PERS_DIR" output -raw project_name)"
    [ "$existing" = "$PROJECT_NAME" ] \
      || fail "project_name is immutable: state has '$existing', requested '$PROJECT_NAME'. A rename forces DB replacement — keep '$existing' (set PROJECT_NAME=$existing)."
  fi

  terraform -chdir="$PERS_DIR" apply -auto-approve -input=false
  DATABASE_URL="$(terraform -chdir="$PERS_DIR" output -raw database_url)"
  DATABASE_CA_CERT="$(terraform -chdir="$PERS_DIR" output -raw database_ca_cert)"
  DOMAIN="$(terraform -chdir="$PERS_DIR" output -raw domain)"
}

# Ensure a DO Container Registry exists; capture its name.
ensure_registry() {
  if doctl registry get --format Name --no-header >/dev/null 2>&1; then
    REG="$(doctl registry get --format Name --no-header)"
    log "registry: using existing '$REG'"
  else
    REG="${DOCR_REGISTRY:-$PROJECT_NAME}"
    log "registry: creating '$REG' (starter tier)"
    doctl registry create "$REG" --subscription-tier starter >/dev/null
  fi
}

# Auto-detect this machine's public IP for the SSH firewall rule (the friction we hit).
detect_cidr() {
  SSH_CIDRS_JSON="${SSH_CIDRS:-}"
  if [ -z "$SSH_CIDRS_JSON" ]; then
    local ip; ip="$(curl -fsS https://ifconfig.me 2>/dev/null || curl -fsS https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || fail "could not auto-detect public IP — set SSH_CIDRS='[\"x.x.x.x/32\"]'"
    SSH_CIDRS_JSON="[\"$ip/32\"]"
    log "ssh allow: $ip/32 (auto-detected)"
  fi
}

# Provision the droplet + firewall (reads persistent state via remote_state).
tf_app() {
  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_ssh_key_name="$SSH_KEY_NAME"
  export TF_VAR_ssh_cidrs="$SSH_CIDRS_JSON"
  export TF_VAR_state_bucket="$STATE_BUCKET"
  export TF_VAR_state_endpoint="$STATE_ENDPOINT"

  log "terraform: infra-app"
  backend_init "$APP_TF_DIR"
  terraform -chdir="$APP_TF_DIR" apply -auto-approve -input=false
  APP_IP="$(terraform -chdir="$APP_TF_DIR" output -raw app_ip)"
  FW_ID="$(terraform -chdir="$APP_TF_DIR" output -raw firewall_id)"
}

# Block until cloud-init has installed Docker (the "docker: command not found" gap).
wait_droplet_ready() {
  log "waiting for droplet Docker readiness ($APP_IP)..."
  # The reserved IP survives droplet recreation but the host key doesn't;
  # accept-new won't replace a changed key. Post-apply, the new key is the
  # ground truth — drop any stale entry so the poll below can pin it.
  ssh-keygen -R "$APP_IP" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    if ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
         root@"$APP_IP" docker --version >/dev/null 2>&1; then
      log "droplet ready."
      return 0
    fi
    sleep 10
  done
  fail "droplet not Docker-ready after ~5min — check cloud-init (cloud-init status --long)"
}

# Generate release.ex (if missing), enforce DB TLS, drop in the pipeline files.
# Order matters: gen.release BEFORE copying our Dockerfile (it writes its own).
prep_app() {
  log "preparing app: deps, release files, TLS, pipeline files"
  ( cd "$APP_DIR"
    mix deps.get
    [ -d rel ] || mix phx.gen.release
  )
  cp "$SCRIPT_DIR/app/Dockerfile"     "$APP_DIR/Dockerfile"
  cp "$SCRIPT_DIR/app/.dockerignore"  "$APP_DIR/.dockerignore"
  mkdir -p "$APP_DIR/.github/workflows" "$APP_DIR/deploy"
  cp "$SCRIPT_DIR/app/.github/workflows/deploy.yml"   "$APP_DIR/.github/workflows/deploy.yml"
  cp "$SCRIPT_DIR/app/.github/workflows/rollback.yml" "$APP_DIR/.github/workflows/rollback.yml"
  cp "$SCRIPT_DIR/deploy/compose.yaml" "$SCRIPT_DIR/deploy/Caddyfile" "$SCRIPT_DIR/deploy/swap.sh" "$APP_DIR/deploy/"
  "$SCRIPT_DIR/scripts/ensure-db-tls.sh" "$APP_DIR"
  "$SCRIPT_DIR/scripts/ensure-release-task.sh" "$APP_DIR"
}

# Ensure the app dir is a git repo with a GitHub origin (create private if absent).
ensure_repo() {
  ( cd "$APP_DIR"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q -b main
    if git remote get-url origin >/dev/null 2>&1 || gh repo view >/dev/null 2>&1; then
      :
    else
      log "creating private GitHub repo '$APP_NAME'"
      gh repo create "$APP_NAME" --source=. --private --remote=origin
    fi
  )
}

# Seed CI secrets/vars. Secrets piped via stdin so ecto:// values aren't mangled.
seed_github() {
  log "seeding GitHub secrets + variables"
  ( cd "$APP_DIR"
    printf '%s' "$DIGITALOCEAN_ACCESS_TOKEN" | gh secret set DIGITALOCEAN_ACCESS_TOKEN
    gh secret set SSH_PRIVATE_KEY < "$SSH_PRIVATE_KEY"
    printf '%s' "$DATABASE_URL"               | gh secret set DATABASE_URL
    printf '%s' "$DATABASE_CA_CERT"           | gh secret set DATABASE_CA_CERT
    mix phx.gen.secret                         | gh secret set SECRET_KEY_BASE
    gh variable set DOCR_REGISTRY -b "$REG"
    gh variable set DOMAIN        -b "$DOMAIN"
    gh variable set DROPLET_HOST  -b "$APP_IP"
    gh variable set FIREWALL_ID   -b "$FW_ID"
  )
}

# Commit + push -> triggers CI = the FIRST deploy via the SAME path as later ones.
commit_push() {
  log "commit + push (triggers first deploy via CI)"
  ( cd "$APP_DIR"
    git add -A
    if git diff --cached --quiet; then
      log "nothing new to commit"
    else
      git commit -q -m "chore: wire push-button deploy pipeline"
    fi
    git push -u origin main
  )
  HEAD_SHA="$(cd "$APP_DIR" && git rev-parse HEAD)"
}

# ---- story 6.3: confirm liveness ----------------------------------------------

# Status of the deploy run for the commit we just pushed: "status conclusion".
# Empty until GitHub registers the run.
run_state() {
  ( cd "$APP_DIR" \
    && gh run list --workflow deploy.yml --commit "$HEAD_SHA" --limit 1 \
         --json status,conclusion --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null
  ) || true
}

# Ordered diagnostics (AC 6.3): Actions status, dig, Caddy logs. Always exits 1 —
# the verdict line above the dump says whether this is "deploy failed" or merely
# "not ready yet".
diagnose() {
  {
    printf '\nbootstrap: NOT LIVE — %s\n' "$1"
    printf '\n--- 1. GitHub Actions (deploy workflow) ---\n'
    ( cd "$APP_DIR" && gh run list --workflow deploy.yml --limit 3 ) \
      || echo "(gh run list failed)"
    printf '\n--- 2. DNS: dig +short %s (expect %s) ---\n' "$DOMAIN" "$APP_IP"
    dig +short "$DOMAIN" || true
    printf '\n--- 3. Caddy logs (last 40 lines) ---\n'
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      root@"$APP_IP" 'cd /root && docker compose logs --tail 40 caddy' 2>&1 \
      || echo "(caddy logs unavailable — stack may not be up yet)"
    printf '\nnext: gh run watch (in %s); after a fix, re-run ./bootstrap.sh (idempotent)\n' "$APP_DIR"
  } >&2
  exit 1
}

# Poll https://<domain> until it answers or LIVE_TIMEOUT_SECS elapses. While
# polling, watch the CI run: a concluded failure aborts immediately ("deploy
# failed") instead of waiting out the clock. On timeout the verdict depends on
# the run's state, distinguishing "not ready yet" from "deploy failed".
confirm_live() {
  local timeout="${LIVE_TIMEOUT_SECS:-900}" waited=0 state
  log "polling https://$DOMAIN (timeout ${timeout}s)..."
  while :; do
    if curl -fsS -o /dev/null --max-time 10 "https://$DOMAIN"; then
      log "LIVE: https://$DOMAIN"
      return 0
    fi
    state="$(run_state)"
    case "$state" in
      "completed failure"|"completed cancelled"|"completed timed_out")
        diagnose "deploy FAILED — CI run concluded '${state#completed }'. See run log: gh run view --log-failed" ;;
    esac
    [ "$waited" -lt "$timeout" ] \
      || case "$state" in
           "completed success")
             diagnose "deploy succeeded but HTTPS not answering after ${timeout}s — likely DNS propagation or Let's Encrypt issuance; see dig/Caddy below" ;;
           *)
             diagnose "not ready yet (CI still running after ${timeout}s — NOT a failure). Keep watching: gh run watch" ;;
         esac
    sleep 10; waited=$((waited + 10))
  done
}

provision() {
  preflight
  ensure_app
  parse_meta
  ensure_state_bucket
  tf_persistent
  ensure_registry
  detect_cidr
  tf_app
  wait_droplet_ready
  prep_app
  ensure_repo
  seed_github
  commit_push
  confirm_live
  log "done. app live at https://$DOMAIN | droplet: $APP_IP"
}

# ---- main --------------------------------------------------------------------

# Absolute path for a directory that may not exist yet (it gets generated).
abs_dir() {
  if [ -d "$1" ]; then (cd "$1" && pwd); else
    case "$1" in
      /*) printf '%s\n' "$1" ;;
      *)  printf '%s/%s\n' "$PWD" "$1" ;;
    esac
  fi
}

main() {
  if [ "${1:-}" = "--check" ]; then
    APP_DIR="$(abs_dir "${2:-.}")"
    preflight
    exit 0
  fi
  case "${1:-}" in
    -*) fail "unknown argument: $1 (use --check or [app_dir])" ;;
  esac
  APP_DIR="$(abs_dir "${1:-.}")"
  provision
}

main "$@"
