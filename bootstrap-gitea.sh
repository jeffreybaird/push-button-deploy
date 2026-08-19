#!/usr/bin/env bash
#
# bootstrap-gitea.sh — stand up a self-hosted Gitea instance + Actions runner,
# so bootstrap.sh's GIT_PROVIDER=gitea path has something real to talk to.
#
#   ./bootstrap-gitea.sh --check   # verify prerequisites, exit non-zero on first gap
#   ./bootstrap-gitea.sh           # provision + configure + start
#   ./bootstrap-gitea.sh --replace-droplet
#                                  # recreate the droplet instead of updating
#                                  # it in place. Needed to DOWNSIZE, since
#                                  # DigitalOcean refuses a resize onto a plan
#                                  # with a smaller disk ("This size is not
#                                  # available because it has a smaller disk")
#                                  # even with resize_disk = false. Keeps the
#                                  # data volume, reserved IP and DNS record;
#                                  # rebuilds only Docker + the images.
#
# One droplet, on its own dedicated infra (infra-gitea/): Gitea server + its
# Actions runner co-located (see README "Gitea support" for why — the short
# version: simplest, cheapest, and this isn't a per-app thing to split).
#
# Reuses the SAME DigitalOcean/DNSimple/Spaces credentials bootstrap.sh
# already needs (same .env works for both) plus a handful of Gitea-specific
# ones for the one-time admin account:
#   GITEA_ADMIN_EMAIL      required — no sensible default.
#   GITEA_ADMIN_USER       default "gitea-admin". NOT "admin" — Gitea
#                          reserves that name (and api/user/org/explore/...);
#                          preflight rejects a reserved one up front.
#   GITEA_ADMIN_PASSWORD   default: auto-generated (openssl rand), cached
#                          locally and printed once.
#   GITEA_DNS_RECORD       default "git" -> git.<DNS_ZONE>. Deliberately a
#                          separate name from bootstrap.sh's DNS_RECORD (an
#                          app-specific subdomain) so one shared .env can't
#                          collide the two.
#   GITEA_PROJECT_NAME     default "gitea-infra" — names the state-bucket
#                          workspace and infra-gitea's resources.
#   GITEA_REGION           default "nyc3".
#   GITEA_DROPLET_SIZE     default "s-1vcpu-1gb". Sized for a zola workload;
#                          bump for heavier CI (sinatra ~s-1vcpu-2gb, phoenix
#                          ~s-2vcpu-4gb). Sizing up is painless, down is not
#                          — see infra-gitea/variables.tf.
#   GITEA_DATA_VOLUME_GB   default 40.
#   SSH_CIDRS              same var bootstrap.sh uses — admin SSH access to
#                          THIS droplet. (Separate from Gitea's own git+ssh
#                          clone port, which is open to the world.)
#
# At the end, prints GITEA_URL / GITEA_TOKEN / GITEA_RUNNER_IP — add those
# (plus GIT_PROVIDER=gitea) to the .env you run bootstrap.sh with.
#
# Idempotent: safe to re-run. The admin user/token/runner-registration steps
# each detect prior completion rather than redo it (Gitea only shows a
# token/password at CREATION time — re-running does not print a new one).
#
# Being verified against a live instance as issues surface. Confirmed fixes
# already folded in, all found that way:
#   - infra-gitea/cloud-init.yaml must be pure ASCII: an em-dash in a comment
#     made cloud-init discard the whole user-data as invalid, so Docker was
#     never installed (cloud-init reported "done", degraded — not "stuck").
#   - gitea-host/docker-compose.yaml must NOT set START_SSH_SERVER=true: the
#     image already runs sshd on :22 in the container, and the two racing for
#     that port left it crash-looping.
#   - GITEA__security__INSTALL_LOCK=true is REQUIRED for a headless
#     env-var-driven setup, or the CLI reports the instance as not-installed
#     no matter what (/api/healthz answering doesn't catch this — it is a
#     liveness check, not an install check).
#   - every gitea CLI call needs `-u 1000` (exec defaults to root, which the
#     gitea binary refuses to run as) and `--config /data/gitea/conf/app.ini`
#     (points it at the config the entrypoint generated).
# If a later step fails, `docker compose
# exec -u 1000 gitea gitea admin user --help` (or
# names/output format against the actual image version running.
# ensure_admin_token()/ensure_runner() parse CLI output defensively and fail
# loud with the raw output if a parse doesn't match.
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

# ---- logging & failure visibility (mirrors bootstrap.sh) ----------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/bootstrap-gitea.log"
: > "$LOG_FILE"

ts()    { date +%H:%M:%S; }
log()   { printf '\033[32m==>\033[0m [%s] %s\n' "$(ts)" "$*"; printf '==> [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
warn()  { printf '\033[33m==> WARN\033[0m [%s] %s\n' "$(ts)" "$*" >&2; printf 'WARN [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
fail()  { printf '\033[31mbootstrap-gitea: %s\033[0m\n' "$*" >&2; printf 'FAIL [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

STEP=0; TOTAL_STEPS=12
step() {
  STEP=$((STEP + 1))
  printf '\033[36m==> [%s] step %s/%s:\033[0m %s\n' "$(ts)" "$STEP" "$TOTAL_STEPS" "$*"
  printf '==> [%s] step %s/%s: %s\n' "$(ts)" "$STEP" "$TOTAL_STEPS" "$*" >> "$LOG_FILE"
}

# Run a command console-quiet: full output goes to the transcript. On failure,
# replay the tail to the console and die loud. Same redaction as bootstrap.sh
# (URL userinfo, --user) — nothing here routes a raw secret through quiet()
# as a bare command-line arg (see ensure_admin_user/ensure_admin_token for the
# narrower, unavoidable exposure of the initial admin password to the REMOTE
# droplet's own process listing, documented there).
quiet() {
  printf '\n$ %s\n' "$(printf '%s ' "$@" | sed -E 's|://[^@ ]*@|://<redacted>@|g; s|--user [^ ]+|--user <redacted>|g')" >> "$LOG_FILE"
  local rc=0
  "$@" >> "$LOG_FILE" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '\033[31m==> command failed (exit %s)\033[0m — last output:\n' "$rc" >&2
    tail -25 "$LOG_FILE" | sed 's/^/    /' >&2
    fail "step ${STEP}/${TOTAL_STEPS} died (full transcript: $LOG_FILE)"
  fi
}

set -E
trap 'printf "\033[31mbootstrap-gitea: unexpected failure at line %s (running: %s)\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
        printf "\033[31m==> bootstrap-gitea FAILED (exit %s) at step %s/%s\033[0m — transcript: %s\n" "$rc" "$STEP" "$TOTAL_STEPS" "$LOG_FILE" >&2
      else
        printf "==> run OK\n" >> "$LOG_FILE"
      fi' EXIT

# ---- .env (same precedence rule as bootstrap.sh: the calling shell wins) ------
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
      [ "$_was" != "${!_k}" ] && warn "$_k: using '${!_k}' from the environment, not '$_was' from .env"
    done < "$_envtmp"
  fi
  rm -f "$_envtmp"
  unset _envtmp _k _line _was
fi

# ---- config resolution (after .env, same reasoning as bootstrap.sh) -----------
GITEA_PROJECT_NAME="${GITEA_PROJECT_NAME:-gitea-infra}"
GITEA_REGION="${GITEA_REGION:-nyc3}"
GITEA_DNS_RECORD="${GITEA_DNS_RECORD:-git}"
GITEA_DROPLET_SIZE="${GITEA_DROPLET_SIZE:-s-1vcpu-1gb}"
GITEA_DATA_VOLUME_GB="${GITEA_DATA_VOLUME_GB:-40}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea-admin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-}"
GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-}"
GITEA_RUNNER_NAME="${GITEA_RUNNER_NAME:-gitea-host}"

# --replace-droplet: recreate the droplet instead of updating it in place.
REPLACE_DROPLET=0

# Local caches (gitignored): Gitea shows a token/password ONCE, at creation.
# Re-running this script must not try to mint a second one where the first
# still works.
TOKEN_CACHE="$SCRIPT_DIR/.gitea-admin-token"
PASSWORD_CACHE="$SCRIPT_DIR/.gitea-admin-password"

# scripts/tfstate.sh reads the generic STATE_BUCKET/SPACES_REGION names — but
# this .env is SHARED with bootstrap.sh, whose users may have set STATE_BUCKET
# there as a per-APP override. Never let that leak into Gitea's own bucket
# naming: only ever honor a GITEA_-prefixed override here.
STATE_BUCKET="${GITEA_STATE_BUCKET:-}"
SPACES_REGION="${GITEA_SPACES_REGION:-}"

REQUIRED_BINS="git terraform doctl curl ssh scp dig jq openssl"
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY GITEA_ADMIN_EMAIL"

# Terraform roots. infra-gitea and infra-state are applied DIRECTLY from this
# repo — unlike infra-app/infra-persistent, nothing here is copied into a
# per-project app repo, because there's exactly one Gitea instance, not one
# per app.
GITEA_TF_DIR="$SCRIPT_DIR/infra-gitea"
STATE_TF_DIR="$SCRIPT_DIR/infra-state"

# Same fallback binaries as bootstrap.sh; shares the state-bucket bootstrap
# logic rather than duplicating it (scripts/tfstate.sh).
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
# shellcheck source=scripts/tfstate.sh
. "$SCRIPT_DIR/scripts/tfstate.sh"

# ---- preflight ------------------------------------------------------------------
preflight() {
  local b v val
  for b in $REQUIRED_BINS; do
    have "$b" || fail "missing binary: $b"
  done
  for v in $REQUIRED_ENV; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || fail "missing env var: $v"
  done
  [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"

  # Gitea refuses to create a user whose name is on its reserved list, and it
  # only says so at creation time — which is step 9, long after a droplet has
  # been provisioned and paid for. Catch the likely picks here instead, in
  # --check. Gitea's own list is the authority and grows across versions, so
  # this is a courtesy check, not a mirror of it: an unlisted reserved name
  # still fails later with Gitea's own "name is reserved" message.
  case " admin api assets attachments avatar avatars captcha commits debug devtest error explore favicon.ico ghost gitea-actions issues login metrics milestones new notifications org pulls raw repo repo-avatars search ssh_info user v2 " in
    *" $GITEA_ADMIN_USER "*)
      fail "GITEA_ADMIN_USER='$GITEA_ADMIN_USER' is a name Gitea reserves — creating it fails with 'name is reserved'. Pick another (the default, 'gitea-admin', is fine)." ;;
  esac

  doctl account get >/dev/null 2>&1 \
    || fail "doctl not authenticated — run: doctl auth init"

  local ssh_keys
  ssh_keys="$(doctl compute ssh-key list --no-header --format Name)" \
    || fail "doctl compute ssh-key list failed (API error above) — retry"
  printf '%s\n' "$ssh_keys" | grep -qx "$SSH_KEY_NAME" \
    || fail "SSH key '$SSH_KEY_NAME' not found in DO account (doctl compute ssh-key list)"

  # A leftover tfvars file would silently override bootstrap's TF_VAR_ env
  # (Terraform precedence: tfvars beats env) — same guard bootstrap.sh applies.
  local f
  for f in "$GITEA_TF_DIR"/terraform.tfvars "$GITEA_TF_DIR"/terraform.tfvars.json \
           "$GITEA_TF_DIR"/*.auto.tfvars "$GITEA_TF_DIR"/*.auto.tfvars.json; do
    [ -e "$f" ] && fail "$f would override bootstrap-gitea's variables (terraform precedence: tfvars beats TF_VAR_ env). Move it aside: mv '$f' '$f.bak'"
  done

  echo "preflight: OK — all prerequisites present."
}

# Auto-detect this machine's public IP for the admin-SSH firewall rule (same
# logic as bootstrap.sh's detect_cidr).
detect_cidr() {
  SSH_CIDRS_JSON="${SSH_CIDRS:-}"
  if [ -z "$SSH_CIDRS_JSON" ]; then
    local ip; ip="$(curl -fsS https://ifconfig.me 2>/dev/null || curl -fsS https://api.ipify.org 2>/dev/null || true)"
    [ -n "$ip" ] || fail "could not auto-detect public IP — set SSH_CIDRS='[\"x.x.x.x/32\"]'"
    SSH_CIDRS_JSON="[\"$ip/32\"]"
    log "ssh allow: $ip/32 (auto-detected)"
  fi
}

# Provision the Gitea droplet + firewall + volume + DNS record.
tf_gitea() {
  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_project_name="$GITEA_PROJECT_NAME"
  export TF_VAR_region="$GITEA_REGION"
  export TF_VAR_droplet_size="$GITEA_DROPLET_SIZE"
  export TF_VAR_data_volume_gb="$GITEA_DATA_VOLUME_GB"
  export TF_VAR_ssh_key_name="$SSH_KEY_NAME"
  export TF_VAR_ssh_cidrs="$SSH_CIDRS_JSON"
  export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
  export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
  export TF_VAR_dns_zone="$DNS_ZONE"
  export TF_VAR_dns_record="$GITEA_DNS_RECORD"

  log "terraform: infra-gitea"
  backend_init "$GITEA_TF_DIR"
  if [ "$REPLACE_DROPLET" = 1 ]; then
    # Recreating rather than updating. Safe by design: every stateful thing
    # lives on the attached volume (Gitea's DB + repos, Caddy's certs, the
    # runner's registration), the reserved IP is its own resource, and
    # cloud-init mounts the volume without ever formatting it. What is lost
    # is the root disk: Docker Engine and the pulled images, both rebuilt by
    # the remaining steps of this run.
    log "REPLACING the droplet (data volume + reserved IP are untouched)"
    terraform -chdir="$GITEA_TF_DIR" apply -auto-approve -input=false \
      -replace=digitalocean_droplet.gitea
  else
    terraform -chdir="$GITEA_TF_DIR" apply -auto-approve -input=false
  fi
  GITEA_IP="$(terraform -chdir="$GITEA_TF_DIR" output -raw gitea_ip)"
  GITEA_DOMAIN="$(terraform -chdir="$GITEA_TF_DIR" output -raw domain)"
  GITEA_URL="https://$GITEA_DOMAIN"
}

# Block until cloud-init has installed Docker (same probe bootstrap.sh uses).
wait_droplet_ready() {
  log "waiting for droplet Docker readiness ($GITEA_IP)..."
  ssh-keygen -R "$GITEA_IP" >/dev/null 2>&1 || true
  local i
  for i in $(seq 1 30); do
    if ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
         root@"$GITEA_IP" docker info >/dev/null 2>&1; then
      log "droplet ready (Docker daemon answering)."
      return 0
    fi
    log "  not ready yet (attempt $i/30, ~$((i * 10))s) — cloud-init still installing Docker"
    sleep 10
  done
  fail "droplet not Docker-ready after ~5min — check cloud-init (cloud-init status --long)"
}

remote_ssh() { ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 root@"$GITEA_IP" "$@"; }
remote_scp() { scp -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new "$@"; }

copy_gitea_files() {
  remote_ssh "mkdir -p /root/gitea"
  remote_scp "$SCRIPT_DIR/gitea-host/docker-compose.yaml" "$SCRIPT_DIR/gitea-host/Caddyfile" \
    root@"$GITEA_IP":/root/gitea/
}

# Writes/overwrites the droplet's runtime .env. Called twice: once before
# Gitea/Caddy start (no runner token yet — nothing has generated one), and
# again once ensure_runner() has a fresh registration token to hand the
# runner container. Same "just re-ship the file" idiom the app deploy
# workflows use, rather than editing it in place remotely.
write_gitea_env() { # $1: registration token (optional, empty = none yet)
  remote_ssh "umask 077; cat > /root/gitea/.env" <<EOF
GITEA_DOMAIN=$GITEA_DOMAIN
GITEA_RUNNER_NAME=$GITEA_RUNNER_NAME
GITEA_RUNNER_REGISTRATION_TOKEN=${1:-}
EOF
}

start_core_services() {
  write_gitea_env ""
  remote_ssh "cd /root/gitea && docker compose up -d caddy gitea"
}

# Gitea's readiness is checked INTERNALLY (inside the container, over SSH),
# not via public HTTPS — decouples "is the app up" from "has DNS propagated
# and Let's Encrypt issued a cert yet" (that's a separate, slower thing;
# confirm_summary() checks it last, informationally).
wait_gitea_healthy() {
  log "waiting for Gitea to answer internally..."
  local i restarts
  for i in $(seq 1 30); do
    if remote_ssh "cd /root/gitea && docker compose exec -T gitea curl -fsS http://localhost:3000/api/healthz" >/dev/null 2>&1; then
      log "Gitea is answering."
      return 0
    fi

    # A crash-looping container never becomes healthy, so polling it for the
    # full 5 minutes only delays a failure that is already certain — and the
    # reason is sitting in its logs the whole time. Docker's restart counter
    # is the tell: a container that is merely slow to start never restarts at
    # all. Bail as soon as it is clearly looping and print the logs, rather
    # than timing out and telling the operator to go read them by hand.
    restarts="$(remote_ssh "cd /root/gitea && cid=\$(docker compose ps -q gitea) && docker inspect -f '{{.RestartCount}}' \$cid" 2>/dev/null || true)"
    case "$restarts" in
      ''|*[!0-9]*) : ;;   # unavailable / not a number: keep waiting
      *)
        if [ "$restarts" -ge 3 ]; then
          warn "the gitea container has restarted $restarts times — it is crash-looping, not starting slowly. Last 40 log lines:"
          remote_ssh "cd /root/gitea && docker compose logs --tail 40 gitea" >&2 2>/dev/null || true
          fail "Gitea is crash-looping (see the log lines above). Full log: ssh root@$GITEA_IP 'cd /root/gitea && docker compose logs gitea'"
        fi ;;
    esac

    log "  not answering yet (attempt $i/30, ~$((i * 10))s)"
    sleep 10
  done
  fail "Gitea did not answer at /api/healthz after ~5min — check: ssh root@$GITEA_IP 'cd /root/gitea && docker compose logs gitea'"
}

# Idempotent: Gitea's CLI errors on a duplicate username, which is treated as
# success (the user already exists — nothing left to do), not a failure.
ensure_admin_user() {
  if [ -z "$GITEA_ADMIN_PASSWORD" ]; then
    if [ -r "$PASSWORD_CACHE" ]; then
      GITEA_ADMIN_PASSWORD="$(cat "$PASSWORD_CACHE")"
    else
      GITEA_ADMIN_PASSWORD="$(openssl rand -hex 24)"
      ( umask 077; printf '%s' "$GITEA_ADMIN_PASSWORD" > "$PASSWORD_CACHE" )
      log "generated admin password (cached: $PASSWORD_CACHE)"
    fi
  fi

  local out rc=0
  # The password is briefly a plain arg to the REMOTE process — Gitea's CLI
  # has no --password-stdin for this command. Narrow, accepted exposure (only
  # visible to `ps` on a droplet only you SSH into) — see file header.
  #
  # -u 1000: `docker compose exec` defaults to root inside the container, but
  # the gitea binary refuses to run as root ("Gitea is not supposed to be run
  # as root") — confirmed against a live instance. 1000 matches the
  # USER_UID/USER_GID the compose file sets for the git user.
  #
  # --config: points the CLI at the same app.ini the entrypoint generates
  # from the GITEA__* env vars, rather than trusting its own default search
  # (belt-and-suspenders; harmless either way).
  #
  # The actual fix for "Unable to load config file for a installed Gitea
  # instance" (confirmed live — --config alone did NOT resolve it) was
  # gitea-host/docker-compose.yaml's GITEA__security__INSTALL_LOCK=true:
  # without it Gitea considers itself genuinely not-installed no matter what
  # config file is loaded — /api/healthz answering is a liveness check, not
  # an install check, so wait_gitea_healthy() passing didn't catch this.
  # Every gitea CLI invocation below needs -u 1000 and --config for the
  # reasons above.
  out="$(remote_ssh "cd /root/gitea && docker compose exec -T -u 1000 gitea gitea --config /data/gitea/conf/app.ini admin user create --admin --username '$GITEA_ADMIN_USER' --password '$GITEA_ADMIN_PASSWORD' --email '$GITEA_ADMIN_EMAIL' --must-change-password=false" 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$LOG_FILE"
  if [ "$rc" -ne 0 ]; then
    printf '%s' "$out" | grep -qi "already exists" \
      || fail "gitea admin user create failed — see $LOG_FILE for the full output"
    log "admin user '$GITEA_ADMIN_USER' already exists"
  else
    log "admin user '$GITEA_ADMIN_USER' created"
  fi
}

# Idempotent by way of a local cache: Gitea shows a token's value ONCE, at
# creation, so a second `generate-access-token` with the same name errors
# ("already used") rather than reprinting it — re-runs must reuse the cache.
ensure_admin_token() {
  if [ -r "$TOKEN_CACHE" ]; then
    GITEA_TOKEN="$(cat "$TOKEN_CACHE")"
    log "reusing cached admin token ($TOKEN_CACHE)"
    return 0
  fi

  # Scopes needed by scripts/provider.sh's Gitea calls: create/delete a repo,
  # and manage that repo's Actions secrets/variables. VERSION CAVEAT: exact
  # scope names are for Gitea's 1.20+ scoped-token system — check
  # `docker compose exec -u 1000 gitea gitea admin user generate-access-token --help`
  # against your version if this rejects the scope list.
  local out
  out="$(remote_ssh "cd /root/gitea && docker compose exec -T -u 1000 gitea gitea --config /data/gitea/conf/app.ini admin user generate-access-token --username '$GITEA_ADMIN_USER' --token-name bootstrap --scopes write:repository,write:user,write:organization" 2>&1)" \
    || fail "gitea admin user generate-access-token failed: $out"
  printf '%s\n' "$out" >> "$LOG_FILE"

  # Second parse attempt is itself allowed to come up empty (grep -Eo finds no
  # match) without that failure propagating — under pipefail a genuinely
  # empty match makes this WHOLE assignment's exit status non-zero, and as
  # the last element of an `A || B` list that's not otherwise exempt from
  # set -e, it would kill the script here instead of reaching the friendlier
  # fail() two lines down.
  GITEA_TOKEN="$(printf '%s\n' "$out" | sed -nE 's/.*[Cc]reated: *//p' | tr -d '[:space:]')"
  [ -n "$GITEA_TOKEN" ] || GITEA_TOKEN="$(printf '%s\n' "$out" | grep -Eo '[0-9a-zA-Z_]{20,}' | tail -1)" || true
  [ -n "$GITEA_TOKEN" ] || fail "could not parse an access token from Gitea's output — see $LOG_FILE (or generate one by hand in the web UI and set GITEA_TOKEN yourself)"

  ( umask 077; printf '%s' "$GITEA_TOKEN" > "$TOKEN_CACHE" )
  log "admin token generated (cached: $TOKEN_CACHE)"
}

# Idempotent: checks for the runner's own persisted registration
# (/mnt/gitea-data/runner/.runner, on the volume — survives restarts) before
# generating a fresh registration token. Registration tokens can be
# regenerated freely without disturbing an already-registered runner, so this
# check is about not needlessly re-registering, not about avoiding an error.
#
# VERSION CAVEAT: the exact path act_runner writes its config to (here
# assumed to be <mounted /data>/.runner, per the official image's documented
# examples) isn't confirmed against a live instance — if this never detects
# an existing registration, check `docker compose exec runner ls /data` and
# adjust the path below.
ensure_runner() {
  local already
  already="$(remote_ssh "[ -f /mnt/gitea-data/runner/.runner ] && echo yes || echo no")"
  if [ "$already" = "yes" ]; then
    log "runner: already registered — ensuring it's running"
    remote_ssh "cd /root/gitea && docker compose up -d runner"
    return 0
  fi

  log "runner: generating a registration token"
  local out token
  out="$(remote_ssh "cd /root/gitea && docker compose exec -T -u 1000 gitea gitea --config /data/gitea/conf/app.ini actions generate-runner-token" 2>&1)" \
    || fail "gitea actions generate-runner-token failed: $out"
  printf '%s\n' "$out" >> "$LOG_FILE"
  token="$(printf '%s\n' "$out" | tail -1 | tr -d '[:space:]')"
  [ -n "$token" ] || fail "could not parse a runner registration token from Gitea's output — see $LOG_FILE"

  log "runner: registering + starting"
  write_gitea_env "$token"
  remote_ssh "cd /root/gitea && docker compose up -d runner"

  # The registration token is single-use and short-lived by design — no
  # reason to leave it sitting in the droplet's .env once the runner has
  # consumed it and written its own persistent .runner file.
  sleep 5
  write_gitea_env ""
}

confirm_summary() {
  log "checking public HTTPS (informational — DNS/cert issuance can lag a few minutes)..."
  if curl -fsS -o /dev/null --max-time 10 "$GITEA_URL"; then
    log "LIVE: $GITEA_URL"
  else
    warn "$GITEA_URL not answering yet — likely DNS propagation or first Let's Encrypt issuance. It'll catch up; the instance itself is already configured. Check: dig +short $GITEA_DOMAIN (expect $GITEA_IP)"
  fi
  cat <<EOF

==> Gitea is set up. Add these to the .env you run ./bootstrap.sh with:

GIT_PROVIDER=gitea
GITEA_URL=$GITEA_URL
GITEA_TOKEN=$GITEA_TOKEN
GITEA_RUNNER_IP=$GITEA_IP/32

Admin login: $GITEA_URL  user: $GITEA_ADMIN_USER  password: (see $PASSWORD_CACHE)
EOF
}

provision() {
  log "transcript of this run: $LOG_FILE"
  step "preflight checks";                        preflight
  step "Terraform state bucket (infra-state)";    ensure_state_bucket
  step "detect admin-SSH allow CIDR";             detect_cidr
  step "Gitea infra: droplet/firewall/volume/DNS (infra-gitea)"; tf_gitea
  step "wait for droplet Docker daemon";          wait_droplet_ready
  step "copy Gitea + Caddy files to droplet";     copy_gitea_files
  step "start Gitea + Caddy";                     start_core_services
  step "wait for Gitea to answer internally";     wait_gitea_healthy
  step "ensure admin user";                       ensure_admin_user
  step "ensure admin API token";                  ensure_admin_token
  step "ensure Actions runner registered";        ensure_runner
  step "summary";                                 confirm_summary
}

main() {
  local check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      --replace-droplet) REPLACE_DROPLET=1; shift ;;
      -*) fail "unknown argument: $1 (use --check, --replace-droplet)" ;;
      *)  fail "unknown argument: $1 (bootstrap-gitea.sh takes no positional args)" ;;
    esac
  done

  # PROJECT_NAME/REGION here are what scripts/tfstate.sh's ensure_state_bucket
  # names the state workspace/bucket after — Gitea's own, not an app's.
  PROJECT_NAME="$GITEA_PROJECT_NAME"
  REGION="$GITEA_REGION"

  if [ "$check" -eq 1 ]; then
    preflight
    exit 0
  fi
  provision
}

main "$@"
