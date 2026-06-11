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
  # Capture the listing first: a transient API failure must not masquerade as
  # "key not found".
  local ssh_keys
  ssh_keys="$(doctl compute ssh-key list --no-header --format Name)" \
    || fail "doctl compute ssh-key list failed (API error above) — retry"
  printf '%s\n' "$ssh_keys" | grep -qx "$SSH_KEY_NAME" \
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
  # Freshly generated apps get the Claude skill docs (app-template/) and the
  # deps the docs assume. Existing apps are left alone — run the script by
  # hand to retrofit: ./scripts/inject-skill-docs.sh <app_dir>
  "$SCRIPT_DIR/scripts/inject-skill-docs.sh" "$APP_DIR"
}

# Parse APP_NAME / APP_MODULE from the app's mix.exs (single source of truth).
parse_meta() {
  [ -f "$APP_DIR/mix.exs" ] || fail "no mix.exs in $APP_DIR — generation failed?"
  # shellcheck source=scripts/app-meta.sh
  . "$SCRIPT_DIR/scripts/app-meta.sh"
  APP_NAME="$(app_name "$APP_DIR")"
  APP_MODULE="$(app_module "$APP_DIR")"
  # Mix app names are snake_case, but DO buckets/DBs and DNS labels only allow
  # hyphens — translate when deriving infra names from the app name.
  local infra_name; infra_name="$(printf '%s' "$APP_NAME" | tr '_' '-')"
  PROJECT_NAME="${PROJECT_NAME:-$infra_name}"
  case "$PROJECT_NAME" in
    *[!a-z0-9-]*|-*|*-) fail "PROJECT_NAME '$PROJECT_NAME' is invalid: lowercase letters, digits, and inner hyphens only (it names DO buckets/DBs/DNS)" ;;
  esac
  REGION="${REGION:-nyc3}"
  DNS_RECORD="${DNS_RECORD:-$infra_name}"
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
  # A cached backend from a previous project may point at a bucket that no
  # longer exists (torn down) — init would try to migrate state OUT of it and
  # die on the 404. If the cached bucket differs from the current one, drop
  # the cache and start clean.
  local cached
  cached="$(sed -nE 's/.*"bucket": ?"([^"]+)".*/\1/p' "$1/.terraform/terraform.tfstate" 2>/dev/null | head -1)"
  if [ -n "$cached" ] && [ "$cached" != "$STATE_BUCKET" ]; then
    log "backend: cached bucket '$cached' != '$STATE_BUCKET' — reinitializing $(basename "$1")"
    rm -rf "$1/.terraform"
  fi
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  log "backend: init $(basename "$1") against $STATE_BUCKET (silent; may download providers)..."
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
  # Note: on an empty state, `output -raw` exits 0 with empty output, so test the
  # value rather than the exit code.
  local existing
  existing="$(terraform -chdir="$PERS_DIR" output -raw project_name 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "$PROJECT_NAME" ]; then
    fail "project_name is immutable: state has '$existing', requested '$PROJECT_NAME'. A rename forces DB replacement — keep '$existing' (set PROJECT_NAME=$existing)."
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
    # `docker info` needs a RESPONSIVE DAEMON — `docker --version` only proves
    # the binary landed, and cloud-init may still be mid-install at that point.
    if ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
         root@"$APP_IP" docker info >/dev/null 2>&1; then
      log "droplet ready."
      return 0
    fi
    sleep 10
  done
  fail "droplet not Docker-ready after ~5min — check cloud-init (cloud-init status --long)"
}

# PG15+: the app user gets no CREATE on schema public (doadmin owns the DB via
# the DO API), so migrations would die with insufficient_privilege. Grant via
# the droplet — the only host the DB firewall trusts. Idempotent.
grant_db_schema() {
  log "granting schema public privileges to DB user '$PROJECT_NAME'"
  local admin_url
  admin_url="$(terraform -chdir="$PERS_DIR" output -raw database_admin_url)"
  ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new root@"$APP_IP" \
    "docker run --rm postgres:17-alpine psql '$admin_url' -v ON_ERROR_STOP=1 \
       -c 'GRANT ALL ON SCHEMA public TO \"$PROJECT_NAME\";'" >/dev/null
}

# Pin the app's Dockerfile ARGs (CI reads the same ARGs) to the local Elixir/OTP
# that generated the app: phx_new can emit syntax older Elixirs cannot compile
# (e.g. the ~r"..."E regex modifier), so the pipeline toolchain must not lag the
# local one. Overridable via ELIXIR_VERSION / OTP_VERSION env.
pin_toolchain() {
  local df="$APP_DIR/Dockerfile" ex otp debian tag
  ex="${ELIXIR_VERSION:-$(elixir --version 2>/dev/null | sed -nE 's/^Elixir ([0-9.]+).*/\1/p')}"
  otp="${OTP_VERSION:-$(erl -noshell -eval \
    '{ok,V}=file:read_file(filename:join([code:root_dir(),"releases",erlang:system_info(otp_release),"OTP_VERSION"])),io:fwrite(V),halt().' \
    2>/dev/null | tr -d '[:space:]')}"
  [ -n "$ex" ] && [ -n "$otp" ] || fail "could not detect local Elixir/OTP versions (set ELIXIR_VERSION/OTP_VERSION env)"

  # The Dockerfile's DEBIAN_VERSION pins a snapshot like bookworm-YYYYMMDD-slim;
  # only the flavor is authoritative — hexpm republishes on new snapshot dates
  # and drops the old tags, so the date must float to what's published.
  local flavor
  flavor="$(sed -nE 's/^ARG DEBIAN_VERSION=([a-z]+)-.*$/\1/p' "$df" | head -1)"
  [ -n "$flavor" ] || fail "no ARG DEBIAN_VERSION in $df"

  # The combo must exist as a published hexpm builder image or the release
  # build dies mid-pipeline. The repo has thousands of tags, so targeted
  # queries only: first ask for the exact local OTP; if unpublished (hexpm lags
  # new OTP releases), scan the first pages of a descending-by-name listing —
  # that's where the newest OTP versions sit — and take the newest published
  # stable OTP. What matters for compiling the generated app is the Elixir
  # version; OTP only needs to be compatible. Either way pin the newest
  # snapshot date published for the chosen OTP.
  local hub="https://hub.docker.com/v2/repositories/hexpm/elixir/tags" pairs chosen date
  hub_pairs() {
    grep -Eo '"name":"[^"]*"' \
      | sed -nE "s/^\"name\":\"${ex}-erlang-([0-9.]+)-debian-${flavor}-([0-9]+)-slim\"$/\1 \2/p"
  }
  pairs="$(curl -fsSL "${hub}/?page_size=100&name=${ex}-erlang-${otp}-debian-${flavor}-" 2>/dev/null | hub_pairs)"
  if [ -n "$pairs" ]; then
    chosen="$otp"
  else
    local page
    pairs="$(for page in 1 2 3 4 5; do
      curl -fsSL "${hub}/?page_size=100&ordering=name&page=${page}&name=${ex}-erlang-" 2>/dev/null
    done | hub_pairs)"
    [ -n "$pairs" ] \
      || fail "no hexpm/elixir image published for Elixir $ex (debian ${flavor}-*-slim) — pick a combo from hub.docker.com/r/hexpm/elixir/tags and set ELIXIR_VERSION/OTP_VERSION"
    chosen="$(printf '%s\n' "$pairs" | awk '{print $1}' | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n | tail -1)"
    log "toolchain: local OTP $otp has no hexpm image; pinning newest published OTP $chosen"
  fi
  date="$(printf '%s\n' "$pairs" | awk -v o="$chosen" '$1==o {print $2}' | sort -n | tail -1)"

  log "toolchain pins: elixir $ex / otp $chosen / debian ${flavor}-${date}-slim"
  sed -E \
    -e "s/^ARG ELIXIR_VERSION=.*/ARG ELIXIR_VERSION=${ex}/" \
    -e "s/^ARG OTP_VERSION=.*/ARG OTP_VERSION=${chosen}/" \
    -e "s/^ARG DEBIAN_VERSION=.*/ARG DEBIAN_VERSION=${flavor}-${date}-slim/" \
    "$df" > "$df.tmp" && mv "$df.tmp" "$df"
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
  pin_toolchain
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
  grant_db_schema
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
