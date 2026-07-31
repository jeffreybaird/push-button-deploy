#!/usr/bin/env bash
#
# bootstrap.sh — push-button stand-up for a Phoenix or Sinatra app on DigitalOcean.
#
#   ./bootstrap.sh --check [app_dir]   # verify prerequisites, exit non-zero on first gap
#   ./bootstrap.sh [app_dir]           # provision + wire + deploy (default app_dir: .)
#   ./bootstrap.sh --host <host_app_dir> [app_dir]
#                                      # deploy onto a droplet that ALREADY serves
#                                      # <host_app_dir>'s app (a "tenant")
#
# TENANT MODE (--host, or HOST_APP_DIR in the environment): the app is deployed
# onto an existing droplet instead of getting one of its own. It provisions no
# droplet, no reserved IP, no firewall, no state bucket and no database — it
# adds a DNS record pointing at the host's IP, gets its own stack directory,
# compose project and volumes on the droplet, and contributes one site file to
# the droplet's shared Caddy. A tenant must be a SQLite app or a static site
# (FRAMEWORK=zola): a SQLite tenant keeps its own file on its own volume with its
# own Litestream prefix, and a static tenant stores nothing at all.
#
# The host is named by its APP DIRECTORY because that is where its Terraform
# roots live: the tenant reads the host's state for the droplet IP, firewall ID
# and state bucket, so a recreated droplet is picked up automatically.
#
# app_dir may be EMPTY or NOT EXIST YET: a fresh app is generated there
# (Phoenix: mix phx.new <basename>; Sinatra: scripts/new-sinatra-app.sh). An
# existing app is used as-is.
#
# Optional config (env, with defaults):
#   FRAMEWORK         'phoenix' (default), 'sinatra' or 'zola'. Selects the app
#                     stack the bootstrap generates + deploys. 'sinatra' is
#                     SQLite-only and forces DATABASE_BACKEND=sqlite; 'zola' is a
#                     STATIC site with no database at all (DATABASE_BACKEND=none)
#                     and no container image. Chosen once per project.
#   DATABASE_BACKEND  'sqlite' (default) provisions no DB — the app keeps a
#                     SQLite file on the droplet's local disk, replicated to
#                     Spaces by Litestream. 'postgres' provisions a managed
#                     cluster instead (~$15/mo). Chosen once per project at
#                     first apply (it drives app generation + infra); don't flip
#                     it on an existing deploy. Bootstrapping an existing
#                     Postgres project without setting this is refused, not
#                     silently acted on.
#   PROJECT_NAME   infra naming (DB/tag/VPC). Default: the app name. IMMUTABLE after first apply.
#   REGION         DO region slug. Default: nyc3.
#   DNS_RECORD     subdomain in DNS_ZONE. Default: the app name.
#   SSH_CIDRS      JSON list for SSH allow, e.g. ["1.2.3.4/32"]. Default: auto-detected public IP /32.
#   DOCR_REGISTRY  name for a new DO registry if none exists. Default: PROJECT_NAME.
#   STATE_BUCKET   Spaces bucket for Terraform state. Default: <PROJECT_NAME>-tfstate.
#   SPACES_REGION  region for the state bucket (must offer Spaces). Default: REGION.
#
# The app owns its infrastructure: the Terraform roots in this repo are
# templates, copied once into <app_dir>/infra/{state,persistent,app} and applied
# from there, so a deploy change is a commit in the app repo. Existing copies
# are never overwritten (drift from the templates is reported instead).
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

# ---- logging & failure visibility ----------------------------------------------
# Nothing fails silently:
#  - every run writes a full transcript to bootstrap.log (gitignored)
#  - quiet commands log there; on failure their output is replayed to the console
#  - an ERR trap names the exact line/command of any unguarded failure
#  - an EXIT trap stamps the run FAILED/OK so a half-run can't read as success
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="$SCRIPT_DIR/bootstrap.log"
: > "$LOG_FILE"

ts()    { date +%H:%M:%S; }
# log to console AND transcript
log()   { printf '\033[32m==>\033[0m [%s] %s\n' "$(ts)" "$*"; printf '==> [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
warn()  { printf '\033[33m==> WARN\033[0m [%s] %s\n' "$(ts)" "$*" >&2; printf 'WARN [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; }
fail()  { printf '\033[31mbootstrap: %s\033[0m\n' "$*" >&2; printf 'FAIL [%s] %s\n' "$(ts)" "$*" >> "$LOG_FILE"; exit 1; }
have()  { command -v "$1" >/dev/null 2>&1; }

# Database backend selector. 'sqlite' (default) = a file on the droplet,
# replicated to Spaces by Litestream; 'postgres' = a managed cluster (~$15/mo).
# is_sqlite gates every backend-specific branch below.
#
# SQLite is the default because it is the right answer for the apps this tool
# builds: one small droplet, one writer, traffic that fits in a file. Reach for
# postgres when you actually need concurrent writers, or SQL that SQLite lacks.
#
# The choice is per-project and effectively permanent. Running an existing
# Postgres project WITHOUT setting DATABASE_BACKEND=postgres would ask Terraform
# to tear its cluster down — tf_persistent refuses rather than let that happen.
is_sqlite() { [ "$DATABASE_BACKEND" = "sqlite" ]; }

# Application framework selector. 'phoenix' (default) generates + deploys a
# Phoenix/Elixir app; 'sinatra' a Sinatra/Ruby app (Sequel + Puma). is_sinatra /
# is_phoenix gate every framework-specific branch. The Sinatra path is
# SQLite-only (Sequel + Litestream), so choosing it forces the sqlite backend.
# 'zola' is a STATIC site: `zola build` produces a directory, CI ships it to the
# droplet as a release, and the shared Caddy serves those files directly. There
# is no app container, no image in the registry and no database — which is why it
# forces DATABASE_BACKEND=none rather than picking one.
is_sinatra() { [ "$FRAMEWORK" = "sinatra" ]; }
is_phoenix() { [ "$FRAMEWORK" = "phoenix" ]; }
is_zola()    { [ "$FRAMEWORK" = "zola" ]; }
# A static site has no server-side runtime, so every dynamic-stack step below
# (image build, blue/green swap, migrations, runtime secrets) is skipped or
# replaced. is_static names that where the reason is "no app process" rather than
# "Zola specifically" — the next static generator reuses the same branches.
is_static()  { is_zola; }

# Tenant mode: deploy onto a droplet another app already owns (--host, or
# HOST_APP_DIR in the environment). is_tenant gates every step that would
# otherwise provision host-owned infrastructure.
#
# Tenants are SQLite-only, deliberately. Sharing a droplet is a cost decision,
# and the Postgres path's per-app cluster costs three times the droplet it would
# be sharing; putting several apps in ONE cluster is a different feature (users,
# grants and firewall rules per tenant) and not this one. Each SQLite tenant
# keeps its own file on its own volume with its own Litestream prefix, so they
# are isolated from each other without any of that.
HOST_APP_DIR="${HOST_APP_DIR:-}"
is_tenant() { [ -n "$HOST_APP_DIR" ]; }

# Numbered step banner — the heartbeat of a run. If output stops after a step
# banner, THAT step is where it stopped.
STEP=0; TOTAL_STEPS=16
step() {
  STEP=$((STEP + 1))
  printf '\033[36m==> [%s] step %s/%s:\033[0m %s\n' "$(ts)" "$STEP" "$TOTAL_STEPS" "$*"
  printf '==> [%s] step %s/%s: %s\n' "$(ts)" "$STEP" "$TOTAL_STEPS" "$*" >> "$LOG_FILE"
}

# Run a command console-quiet: full output goes to the transcript. On failure,
# replay the tail to the console and die loud. Secrets in the command line are
# redacted in the transcript (URL userinfo).
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

# set -e kills the script on any unguarded failure — without this trap it does
# so SILENTLY, which reads as success. Name the line so the gap is findable.
# (-E so the trap also fires for failures inside functions.)
set -E
trap 'printf "\033[31mbootstrap: unexpected failure at line %s (running: %s)\033[0m\n" "$LINENO" "$BASH_COMMAND" >&2' ERR
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
        printf "\033[31m==> bootstrap FAILED (exit %s) at step %s/%s\033[0m — transcript: %s\n" "$rc" "$STEP" "$TOTAL_STEPS" "$LOG_FILE" >&2
      else
        printf "==> run OK\n" >> "$LOG_FILE"
      fi' EXIT

# Local config: a gitignored .env beside this script (see .env.example).
# Shell-sourced, so $HOME etc. expand; `set -a` exports plain KEY=value lines
# (an `export ` prefix also works).
#
# PRECEDENCE: the CALLING SHELL WINS. A value already set in the environment is
# restored after the file is sourced, so a per-run override does what it looks
# like it does:
#
#     DNS_ZONE=other.com ./bootstrap.sh ~/src/site
#
# This used to be the other way round — the file overrode the shell — which made
# per-run overrides silently impossible: the run above would provision against
# whatever .env said and report success, having built the wrong thing. An
# override that differs is announced rather than applied in silence.
if [ -f "$SCRIPT_DIR/.env" ]; then
  _envtmp="$(mktemp)"
  # Every KEY on a plain or `export `-prefixed assignment line.
  for _k in $(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$SCRIPT_DIR/.env"); do
    # ${!_k+x} is set only when the variable EXISTS in the environment, so an
    # explicit empty value still counts as "the caller said so".
    if [ -n "${!_k+x}" ]; then printf '%s=%q\n' "$_k" "${!_k}" >> "$_envtmp"; fi
  done

  set -a
  # shellcheck disable=SC1091
  . "$SCRIPT_DIR/.env"
  set +a

  # Re-apply what the caller set, and say so where the file disagreed. Still
  # inside `set -a`'s effect for these names: they were exported while sourcing.
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

# Resolve FRAMEWORK and DATABASE_BACKEND *here*, after .env — not next to the
# is_* predicates above. The predicates only read the variables, so where they
# are defined is irrelevant; these lines APPLY defaults and coercions, and doing
# that before .env is sourced would let a .env value silently outrank the
# coercion (a FRAMEWORK=sinatra in .env would keep whatever DATABASE_BACKEND the
# same file set, instead of being forced to sqlite).
FRAMEWORK="${FRAMEWORK:-phoenix}"
case "$FRAMEWORK" in
  phoenix|sinatra|zola) ;;
  *) fail "FRAMEWORK must be 'phoenix', 'sinatra' or 'zola' (got '$FRAMEWORK')" ;;
esac

DATABASE_BACKEND="${DATABASE_BACKEND:-sqlite}"
# Sinatra runs on SQLite only (Sequel + Litestream); a static site has no data
# layer at all. Both are FORCED rather than refused, because the common case is a
# shared .env carrying a DATABASE_BACKEND meant for some other project — failing
# there would be obstructive. But an override that changes what gets provisioned
# is never silent: say so when the incoming value actually differed.
_requested_backend="${DATABASE_BACKEND}"
if is_sinatra; then DATABASE_BACKEND="sqlite"; fi
if is_zola;    then DATABASE_BACKEND="none"; fi
# Only 'postgres' is worth a warning: it is the one request whose silent
# downgrade would change what gets provisioned, billed and backed up. Ignoring a
# 'sqlite' on a static site provisions nothing either way, and a shared .env
# naming it is the normal case — warning there would be noise on every run.
if [ "$_requested_backend" = "postgres" ] && [ "$DATABASE_BACKEND" != "postgres" ]; then
  warn "FRAMEWORK=$FRAMEWORK forces DATABASE_BACKEND=$DATABASE_BACKEND — the requested managed Postgres cluster will NOT be provisioned"
fi
unset _requested_backend

# Terraform roots. The ones in THIS repo are templates: every app gets its own
# copy under <app_dir>/infra/ (scripts/sync-infra.sh) and Terraform runs from
# that copy, so an app's infrastructure is versioned with the app and can be
# changed by editing its repo. The templates are seeded once and never
# overwritten afterwards.
TPL_PERS_DIR="$SCRIPT_DIR/infra-persistent"
TPL_APP_TF_DIR="$SCRIPT_DIR/infra-app"
TPL_STATE_TF_DIR="$SCRIPT_DIR/infra-state"
TPL_TENANT_TF_DIR="$SCRIPT_DIR/infra-tenant"

# Set once APP_DIR is known (see main).
set_infra_dirs() {
  PERS_DIR="$APP_DIR/infra/persistent"
  APP_TF_DIR="$APP_DIR/infra/app"
  STATE_TF_DIR="$APP_DIR/infra/state"
  # Tenants have exactly this one root; the three above stay unset on disk.
  TENANT_TF_DIR="$APP_DIR/infra/tenant"
}

# Share provider binaries across projects: switching projects drops each root's
# .terraform (backend cache mismatch), and without this every switch
# re-downloads ~50MB of providers.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$HOME/.terraform.d/plugin-cache}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"

# Framework-specific local tooling: Phoenix generates + prepares the app with
# `mix`; Sinatra scaffolds with bash and only needs `openssl` (fresh session
# secret) — the Ruby build itself happens in Docker/CI, not locally.
REQUIRED_BINS="git terraform doctl gh curl ssh scp dig"
# Zola needs nothing extra locally: the scaffold is plain bash and the build runs
# in CI, so there is no `zola` binary to require.
if is_sinatra; then REQUIRED_BINS="$REQUIRED_BINS openssl"
elif is_phoenix; then REQUIRED_BINS="$REQUIRED_BINS mix"; fi
REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"

# ---- story 6.1: preflight ----------------------------------------------------
# Checks run in order and fail fast, naming the FIRST gap (AC 6.1).
preflight() {
  local b v val

  case "$DATABASE_BACKEND" in
    postgres|sqlite) ;;
    # 'none' is never selectable by hand: it is what FRAMEWORK=zola implies, and
    # the coercion above is the only thing that sets it.
    none) is_zola || fail "DATABASE_BACKEND=none is only valid for FRAMEWORK=zola" ;;
    *) fail "DATABASE_BACKEND must be 'postgres' or 'sqlite' (got '$DATABASE_BACKEND')" ;;
  esac

  # Tenant mode: the host must be a real, already-bootstrapped app directory —
  # the tenant reads its Terraform state for the droplet's IP and firewall, so a
  # host that was never applied has nothing to read.
  if is_tenant; then
    [ -d "$HOST_APP_DIR" ] || fail "host app directory does not exist: $HOST_APP_DIR"
    [ -d "$HOST_APP_DIR/infra/app" ] \
      || fail "$HOST_APP_DIR has no infra/app — it is not a bootstrapped host app (a tenant needs a host that owns a droplet)"
    [ -f "$HOST_APP_DIR/infra/persistent/backend.hcl" ] \
      || fail "$HOST_APP_DIR/infra/persistent/backend.hcl is missing — run the bootstrap on the host app first (it names the shared state bucket)"
    [ "$HOST_APP_DIR" != "$APP_DIR" ] \
      || fail "an app cannot be a tenant of itself (--host and app_dir are the same directory)"
    is_sqlite || is_static \
      || fail "a tenant must be a SQLite app or a static site: a shared droplet with a per-app managed Postgres cluster costs more than the droplet it shares. Unset DATABASE_BACKEND (or set it to sqlite)."
  fi

  for b in $REQUIRED_BINS; do
    have "$b" || fail "missing binary: $b"
  done

  # Bootstrap injects ALL terraform variables via TF_VAR_ env, which tfvars
  # files silently OVERRIDE (terraform precedence: tfvars > env). A leftover
  # tfvars file means stale tokens/CIDRs/names win — fail loudly instead.
  # Both the templates and the app's own copies (which may not exist yet on a
  # first run — a glob over a missing directory simply matches nothing).
  local dir f
  for dir in "$TPL_PERS_DIR" "$TPL_APP_TF_DIR" "$TPL_STATE_TF_DIR" "$TPL_TENANT_TF_DIR" \
             "$PERS_DIR" "$APP_TF_DIR" "$STATE_TF_DIR" "$TENANT_TF_DIR"; do
    for f in "$dir"/terraform.tfvars "$dir"/terraform.tfvars.json "$dir"/*.auto.tfvars "$dir"/*.auto.tfvars.json; do
      [ -e "$f" ] && fail "$f would override bootstrap's variables (terraform precedence: tfvars beats TF_VAR_ env). Move it aside: mv '$f' '$f.bak'"
    done
  done

  for v in $REQUIRED_ENV; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || fail "missing env var: $v"
  done

  [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"

  # Generating a Phoenix app (only when the target has none) needs the phx_new
  # archive. The Sinatra scaffold is pure bash — nothing extra to check.
  if is_phoenix && [ ! -f "$APP_DIR/mix.exs" ]; then
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

# Generate the app when the target directory is empty or missing — this is the
# "empty directory -> deployed app" entry point. An existing app (detected by its
# framework signature file) is used as-is; a non-empty non-app directory is
# refused rather than generated over.
ensure_app() {
  local sig
  if is_sinatra;  then sig="Gemfile"
  elif is_zola;   then sig="config.toml"
  else                 sig="mix.exs"; fi
  if [ -f "$APP_DIR/$sig" ]; then
    log "app: using existing $APP_DIR"
    return 0
  fi
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR")" ]; then
    fail "$APP_DIR is not empty and has no $sig — refusing to generate over it"
  fi

  if is_sinatra; then
    # Scaffolds a Sinatra+Sequel+SQLite app and injects the app-template-ruby
    # skill docs. Existing apps are retrofitted by hand with the same script.
    "$SCRIPT_DIR/scripts/new-sinatra-app.sh" "$APP_DIR"
    return 0
  fi

  if is_zola; then
    # Scaffolds a themeless Zola site (content tree, Tera templates, stylesheet,
    # .zola-version) and injects the app-template-zola skill docs. No local zola
    # binary is involved — the scaffold is written by hand and the build runs in
    # CI. Retrofit an existing site with the same script.
    "$SCRIPT_DIR/scripts/new-zola-site.sh" "$APP_DIR"
    return 0
  fi

  # Phoenix: phx.new insists on creating the directory itself (prompts otherwise).
  [ -d "$APP_DIR" ] && rmdir "$APP_DIR"
  local name parent
  name="$(basename "$APP_DIR")"
  parent="$(dirname "$APP_DIR")"
  # On the SQLite backend, generate an Ecto.Adapters.SQLite3 app (DATABASE_PATH
  # config, no Postgrex) instead of the phx.new Postgres default.
  local db_flag=""
  is_sqlite && db_flag="--database sqlite3"
  log "generating Phoenix app '$name' (mix phx.new --no-install ${db_flag:-postgres})"
  ( cd "$parent" && mix phx.new "$name" --no-install $db_flag )
  # Freshly generated apps get the Claude skill docs (app-template/) and the
  # deps the docs assume. Existing apps are left alone — run the script by
  # hand to retrofit: ./scripts/inject-skill-docs.sh <app_dir>
  "$SCRIPT_DIR/scripts/inject-skill-docs.sh" "$APP_DIR"
}

# Parse APP_NAME / APP_MODULE (single source of truth). Phoenix reads mix.exs;
# Sinatra has no mix.exs, so the app name is the dir basename (also written to
# .app-name for the CI workflows) and the module is its camelized form.
parse_meta() {
  if is_zola; then
    [ -f "$APP_DIR/config.toml" ] || fail "no config.toml in $APP_DIR — scaffold failed?"
    APP_NAME="$(basename "$APP_DIR")"
    case "$APP_NAME" in
      # Hyphens are allowed here where they are not for Phoenix/Sinatra: nothing
      # derives an Elixir atom or a Ruby module from a site's name, and hyphens
      # are the natural spelling for a domain label.
      [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
        fail "site name '$APP_NAME' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names the site + infra" ;;
    esac
    # Nothing evaluates a module for a static site; carried only so the log line
    # and downstream references have a value.
    APP_MODULE="(static site)"
  elif is_sinatra; then
    [ -f "$APP_DIR/Gemfile" ] || fail "no Gemfile in $APP_DIR — scaffold failed?"
    APP_NAME="$(basename "$APP_DIR")"
    case "$APP_NAME" in
      [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*) fail "Sinatra app name '$APP_NAME' must be lower_snake_case (it names the app + infra)" ;;
    esac
    APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')"
  else
    [ -f "$APP_DIR/mix.exs" ] || fail "no mix.exs in $APP_DIR — generation failed?"
    # shellcheck source=scripts/app-meta.sh
    . "$SCRIPT_DIR/scripts/app-meta.sh"
    APP_NAME="$(app_name "$APP_DIR")"
    APP_MODULE="$(app_module "$APP_DIR")"
  fi
  # App names are snake_case, but DO buckets/DBs and DNS labels only allow
  # hyphens — translate when deriving infra names from the app name.
  local infra_name; infra_name="$(printf '%s' "$APP_NAME" | tr '_' '-')"
  PROJECT_NAME="${PROJECT_NAME:-$infra_name}"
  case "$PROJECT_NAME" in
    *[!a-z0-9-]*|-*|*-) fail "PROJECT_NAME '$PROJECT_NAME' is invalid: lowercase letters, digits, and inner hyphens only (it names DO buckets/DBs/DNS)" ;;
  esac
  REGION="${REGION:-nyc3}"
  DNS_RECORD="${DNS_RECORD:-$infra_name}"
  # The app's identity ON THE DROPLET. One droplet can host several apps, so
  # everything that could collide with a neighbour is keyed on this: the stack
  # directory (/root/apps/<slug>), the compose project (hence container and
  # volume names), the shared Caddy's site file, and the per-color network
  # aliases Caddy dials. PROJECT_NAME is already unique per app and already
  # hyphenated, which is what compose project names and DNS labels accept.
  APP_SLUG="$PROJECT_NAME"
  log "app: $APP_NAME ($APP_MODULE) [$FRAMEWORK] | project: $PROJECT_NAME | region: $REGION"
}

# Give the app its own copy of the Terraform roots (<app_dir>/infra/), so the
# infrastructure is versioned alongside the code that runs on it. Seeds missing
# files only — hand edits in the app survive every later bootstrap run, and
# drift from the templates is reported rather than overwritten.
sync_infra() {
  if is_tenant; then
    # One root only. A tenant owns no droplet, IP, bucket or database, and
    # seeding it with the host's roots would hand it a `terraform destroy` that
    # takes the host down.
    "$SCRIPT_DIR/scripts/sync-infra.sh" --tenant "$APP_DIR"
    [ -d "$TENANT_TF_DIR" ] || fail "sync-infra did not create $TENANT_TF_DIR"
    return 0
  fi
  "$SCRIPT_DIR/scripts/sync-infra.sh" "$APP_DIR"
  # Every terraform call below already points at these (set_infra_dirs); this
  # is the step that makes the directories real.
  [ -d "$STATE_TF_DIR" ] || fail "sync-infra did not create $STATE_TF_DIR"
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
  log "init infra-state (output in $LOG_FILE)..."
  quiet terraform -chdir="$STATE_TF_DIR" init -input=false

  # This root keeps LOCAL state (the bucket can't store the state that creates
  # it) — per-project workspaces, or a second project silently inherits the
  # first project's bucket in the shared state file.
  quiet terraform -chdir="$STATE_TF_DIR" workspace select -or-create "$PROJECT_NAME"

  # Adopt a bucket that exists but isn't in this workspace's state yet (e.g.
  # created by the direct-API fallback below, or a previous half-run) — apply
  # would otherwise die on BucketAlreadyExists.
  if ! terraform -chdir="$STATE_TF_DIR" state list 2>/dev/null | grep -q . && bucket_visible; then
    log "importing existing bucket '$STATE_BUCKET' into infra-state ($PROJECT_NAME workspace)"
    quiet terraform -chdir="$STATE_TF_DIR" import -input=false \
      digitalocean_spaces_bucket.tfstate "${STATE_REGION},${STATE_BUCKET}"
  fi

  terraform -chdir="$STATE_TF_DIR" apply -auto-approve -input=false

  # The bucket must answer the S3 API before any backend references it. An
  # unsigned request to a private bucket returns 403 once it exists, 404 while
  # it doesn't. Two failure modes feed this: plain propagation lag, and a DO
  # provider bug observed in the wild where apply reports the bucket created
  # (and refreshes cleanly!) while the S3 API keeps 404ing — for that one we
  # fall back to creating the bucket via the S3 API directly.
  if ! wait_bucket_visible 18; then
    warn "terraform reports bucket '$STATE_BUCKET' but the S3 API 404s it — creating it via the S3 API directly"
    quiet curl -fsS -o /dev/null --max-time 15 -X PUT \
      --aws-sigv4 "aws:amz:${STATE_REGION}:s3" \
      --user "${SPACES_ACCESS_KEY_ID}:${SPACES_SECRET_ACCESS_KEY}" \
      "${STATE_ENDPOINT}/${STATE_BUCKET}/"
    printf '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>' \
      | quiet curl -fsS -o /dev/null --max-time 15 -X PUT \
          --aws-sigv4 "aws:amz:${STATE_REGION}:s3" \
          --user "${SPACES_ACCESS_KEY_ID}:${SPACES_SECRET_ACCESS_KEY}" \
          -T - "${STATE_ENDPOINT}/${STATE_BUCKET}/?versioning"
    wait_bucket_visible 6 \
      || fail "state bucket $STATE_BUCKET still not visible after direct creation — check Spaces status, then re-run"
  fi
  log "state bucket ready: $STATE_BUCKET"
}

# True once the bucket answers the S3 API (200/403 = exists, 404 = not yet).
bucket_visible() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${STATE_BUCKET}.${STATE_REGION}.digitaloceanspaces.com/" || true)"
  [ "$code" = "200" ] || [ "$code" = "403" ]
}

wait_bucket_visible() { # $1: attempts, 5s apart
  local i
  for i in $(seq 1 "$1"); do
    bucket_visible && return 0
    log "  bucket not visible yet (attempt $i/$1)"
    sleep 5
  done
  return 1
}

# Point a root at the Spaces backend and init. -force-copy migrates any
# existing local state into the bucket on first contact (idempotent after).
# $2 (optional): state key, for roots that don't pin one in backend.tf. The host
# roots each own a fixed key because they are alone in their bucket; tenants
# share the HOST's bucket, so every tenant needs a key of its own.
backend_init() {
  # A cached backend from a previous project may point at a bucket that no
  # longer exists (torn down) — init would try to migrate state OUT of it and
  # die on the 404. If the cached bucket differs from the current one, drop
  # the cache and start clean.
  local cached
  cached="$(sed -nE 's/.*"bucket": ?"([^"]+)".*/\1/p' "$1/.terraform/terraform.tfstate" 2>/dev/null | head -1 || true)"
  if [ -n "$cached" ] && [ "$cached" != "$STATE_BUCKET" ]; then
    log "backend: cached bucket '$cached' != '$STATE_BUCKET' — reinitializing $(basename "$1")"
    rm -rf "$1/.terraform"
  fi
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  if [ -n "${2:-}" ]; then
    printf 'key       = "%s"\n' "$2" >> "$1/backend.hcl"
  fi
  log "backend: init $(basename "$1") against $STATE_BUCKET (may download providers; output in $LOG_FILE)..."
  quiet terraform -chdir="$1" init -input=false -force-copy -backend-config=backend.hcl
  log "backend: $(basename "$1") initialized"
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
  export TF_VAR_database_backend="$DATABASE_BACKEND"

  log "terraform: infra/persistent (database backend: $DATABASE_BACKEND)"
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

  # The backend default is sqlite, so an existing POSTGRES project bootstrapped
  # without DATABASE_BACKEND=postgres would plan to destroy its cluster. The
  # cluster's prevent_destroy would abort the apply, but the database and user
  # carry no such guard — Terraform would delete them first and take the data
  # with them. Detect the mismatch from state and refuse before applying.
  # Reads `state list` rather than an output: states created before the sqlite
  # backend existed have no database_backend output to compare against.
  if { is_sqlite || is_static; } && terraform -chdir="$PERS_DIR" state list 2>/dev/null \
       | grep -q '^digitalocean_database_cluster\.pg'; then
    fail "project '$PROJECT_NAME' has a managed Postgres cluster in state, but DATABASE_BACKEND is 'sqlite'.
       Applying would DESTROY that cluster's database and user. If this project still uses Postgres,
       re-run with DATABASE_BACKEND=postgres. To decommission it deliberately, lift the cluster's
       prevent_destroy guard and apply by hand (see README, Teardown)."
  fi

  terraform -chdir="$PERS_DIR" apply -auto-approve -input=false
  DOMAIN="$(terraform -chdir="$PERS_DIR" output -raw domain)"
  if is_static; then
    # No database of any kind, and nothing to replicate: the site is files.
    log "static site: no database, no Litestream replica"
  elif is_sqlite; then
    # No managed DB: the SQLite file lives on the droplet. Define the on-volume
    # path + the Spaces replica target (reuses the Terraform state bucket under a
    # per-app prefix). DATABASE_PATH must match deploy/compose.sqlite.yaml.
    DATABASE_PATH="/data/${APP_NAME}.sqlite3"
    BACKUP_BUCKET="$STATE_BUCKET"
    BACKUP_REGION="$STATE_REGION"
    BACKUP_ENDPOINT="$STATE_ENDPOINT"
    BACKUP_PATH="litestream/${PROJECT_NAME}/${APP_NAME}.sqlite3"
  else
    DATABASE_URL="$(terraform -chdir="$PERS_DIR" output -raw database_url)"
    DATABASE_CA_CERT="$(terraform -chdir="$PERS_DIR" output -raw database_ca_cert)"
  fi
}

# ---- tenant mode -------------------------------------------------------------
# A tenant creates none of the shared infrastructure — it adopts the host's. The
# host's state bucket is the one thing it must be told about, and the host app
# already records it in its own backend.hcl, so read it from there rather than
# asking the operator to repeat it (and get it wrong).
adopt_host_state() {
  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"

  local hcl="$HOST_APP_DIR/infra/persistent/backend.hcl"
  STATE_BUCKET="$(sed -nE 's/^bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  STATE_ENDPOINT="$(sed -nE 's/.*s3[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  [ -n "$STATE_BUCKET" ]   || fail "could not read the state bucket from $hcl"
  [ -n "$STATE_ENDPOINT" ] || fail "could not read the state endpoint from $hcl"
  # The endpoint is https://<region>.digitaloceanspaces.com; the region is the
  # only part of it Litestream needs separately (SigV4 signing).
  STATE_REGION="$(printf '%s' "$STATE_ENDPOINT" | sed -nE 's#^https://([^.]+)\..*#\1#p')"
  [ -n "$STATE_REGION" ] || fail "could not derive the Spaces region from endpoint '$STATE_ENDPOINT'"

  log "tenant: sharing host '$(basename "$HOST_APP_DIR")' — state bucket $STATE_BUCKET ($STATE_REGION)"
}

# Apply the tenant root: one DNS record pointing at the host's droplet. Reads
# the host's app state for the IP and firewall, so nothing has to be copied
# between the two app repos by hand.
tf_tenant() {
  export TF_VAR_project_name="$PROJECT_NAME"
  export TF_VAR_state_bucket="$STATE_BUCKET"
  export TF_VAR_state_endpoint="$STATE_ENDPOINT"
  export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
  export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
  export TF_VAR_dns_zone="$DNS_ZONE"
  export TF_VAR_dns_record="$DNS_RECORD"

  log "terraform: infra/tenant (DNS record on the host's droplet)"
  # Every tenant shares the host's bucket, so the key is per-project.
  backend_init "$TENANT_TF_DIR" "tenants/${PROJECT_NAME}/terraform.tfstate"

  # Same immutability guard the host roots make: PROJECT_NAME names this app's
  # state key and its Litestream prefix, so renaming it strands both.
  local existing
  existing="$(terraform -chdir="$TENANT_TF_DIR" output -raw project_name 2>/dev/null || true)"
  if [ -n "$existing" ] && [ "$existing" != "$PROJECT_NAME" ]; then
    fail "project_name is immutable: state has '$existing', requested '$PROJECT_NAME' (it keys this tenant's state and Litestream replica)."
  fi

  terraform -chdir="$TENANT_TF_DIR" apply -auto-approve -input=false
  DOMAIN="$(terraform -chdir="$TENANT_TF_DIR" output -raw domain)"
  APP_IP="$(terraform -chdir="$TENANT_TF_DIR" output -raw host_ip)"
  FW_ID="$(terraform -chdir="$TENANT_TF_DIR" output -raw firewall_id)"

  if is_static; then
    # A static tenant stores nothing: its releases live under /root/apps/<slug>
    # on the droplet and are rebuilt from git on every deploy.
    log "static site: no database, no Litestream replica"
  else
    # Same SQLite wiring as a host app, keyed on this app's own names so two
    # tenants of one droplet never touch each other's data: separate volume
    # (compose project <slug>), separate file, separate replica prefix.
    DATABASE_PATH="/data/${APP_NAME}.sqlite3"
    BACKUP_BUCKET="$STATE_BUCKET"
    BACKUP_REGION="$STATE_REGION"
    BACKUP_ENDPOINT="$STATE_ENDPOINT"
    BACKUP_PATH="litestream/${PROJECT_NAME}/${APP_NAME}.sqlite3"
  fi

  log "tenant: $DOMAIN -> $APP_IP (droplet shared with $(basename "$HOST_APP_DIR"))"
}

# A static site pushes no image, so it needs no registry — and on the free
# starter tier there is exactly ONE repository per account, which a site that
# never pushes should not be holding.
ensure_registry_unless_static() {
  is_static && { log "static site: no container registry needed"; return 0; }
  ensure_registry
}

# Ensure a DO Container Registry exists; capture its name.
ensure_registry() {
  if doctl registry get --format Name --no-header >/dev/null 2>&1; then
    REG="$(doctl registry get --format Name --no-header)"
    log "registry: using existing '$REG'"
  else
    REG="${DOCR_REGISTRY:-$PROJECT_NAME}"
    log "registry: creating '$REG' (starter tier)"
    quiet doctl registry create "$REG" --subscription-tier starter
    log "registry: created '$REG'"
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

  log "terraform: infra/app"
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
      log "droplet ready (Docker daemon answering)."
      return 0
    fi
    log "  not ready yet (attempt $i/30, ~$((i * 10))s) — cloud-init still installing Docker"
    sleep 10
  done
  if is_tenant; then
    # The droplet is already up and serving the host app, so this is almost
    # never cloud-init — it is the firewall. Port 22 is open to the CIDRs the
    # HOST's infra/app was applied with, and this machine may not be among them.
    fail "cannot reach the shared droplet at $APP_IP over SSH.
       The droplet belongs to $(basename "$HOST_APP_DIR"), and its firewall only
       allows port 22 from the CIDRs that root was applied with. Add this machine:
       SSH_CIDRS='[\"<host-operator-ip>/32\",\"$(curl -fsS https://api.ipify.org 2>/dev/null || echo x.x.x.x)/32\"]' ./bootstrap.sh $HOST_APP_DIR"
  fi
  fail "droplet not Docker-ready after ~5min — check cloud-init (cloud-init status --long)"
}

# PG15+: the app user gets no CREATE on schema public (doadmin owns the DB via
# the DO API), so migrations would die with insufficient_privilege. Grant via
# the droplet — the only host the DB firewall trusts. Idempotent.
grant_db_schema() {
  is_static && { log "static site: no database to grant on"; return 0; }
  is_sqlite && { log "sqlite backend: no managed DB schema grant"; return 0; }
  log "granting schema public privileges to DB user '$PROJECT_NAME' (via droplet)"
  local admin_url
  admin_url="$(terraform -chdir="$PERS_DIR" output -raw database_admin_url)" \
    || fail "could not read database_admin_url output — re-run terraform apply in $PERS_DIR"
  quiet ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new root@"$APP_IP" \
    "docker run --rm postgres:17-alpine psql '$admin_url' -v ON_ERROR_STOP=1 \
       -c 'GRANT ALL ON SCHEMA public TO \"$PROJECT_NAME\";'"
  log "schema grant applied"
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
  # `|| true`: an empty result exits the grep inside hub_pairs nonzero, which
  # under set -e -o pipefail would kill the script SILENTLY mid-assignment.
  pairs="$(curl -fsSL "${hub}/?page_size=100&name=${ex}-erlang-${otp}-debian-${flavor}-" 2>/dev/null | hub_pairs || true)"
  if [ -n "$pairs" ]; then
    chosen="$otp"
  else
    local page
    pairs="$(for page in 1 2 3 4 5; do
      curl -fsSL "${hub}/?page_size=100&ordering=name&page=${page}&name=${ex}-erlang-" 2>/dev/null
    done | hub_pairs || true)"
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

# Pin the Sinatra app's Dockerfile RUBY_VERSION ARG to .ruby-version (single
# source of truth; CI reads the same file). Overridable via RUBY_VERSION env.
pin_ruby() {
  local df="$APP_DIR/Dockerfile" rv
  rv="${RUBY_VERSION:-$(tr -d '[:space:]' < "$APP_DIR/.ruby-version" 2>/dev/null)}"
  [ -n "$rv" ] || { warn "no .ruby-version and no RUBY_VERSION — leaving Dockerfile default"; return 0; }
  sed -E "s/^ARG RUBY_VERSION=.*/ARG RUBY_VERSION=${rv}/" "$df" > "$df.tmp" && mv "$df.tmp" "$df"
  log "toolchain: pinned Dockerfile RUBY_VERSION=$rv"
}

# The deploy-time files that are the SAME for every app: this app's blue/green
# stack (swap.sh) plus the droplet's SHARED edge proxy (Caddyfile, its compose
# file, the per-app site template and the script that installs all three). The
# edge files travel in every app repo on purpose — any app's deploy must be able
# to stand the proxy up, including the first one on a fresh droplet.
copy_deploy_files() {
  # Shared by every framework: the droplet's edge proxy.
  cp "$SCRIPT_DIR/deploy/Caddyfile" \
     "$SCRIPT_DIR/deploy/edge-compose.yaml" \
     "$SCRIPT_DIR/deploy/edge.sh" \
     "$APP_DIR/deploy/"

  # The site file and the publish mechanism differ by what is being served.
  # edge.sh always reads deploy/site.caddy.tmpl, so the right template is copied
  # UNDER THAT NAME rather than teaching edge.sh about frameworks.
  if is_static; then
    # Caddy serves files off disk; publishing is a symlink flip, not a swap.
    cp "$SCRIPT_DIR/deploy/site.static.caddy.tmpl" "$APP_DIR/deploy/site.caddy.tmpl"
    cp "$SCRIPT_DIR/deploy/publish.sh"             "$APP_DIR/deploy/publish.sh"
    rm -f "$APP_DIR/deploy/swap.sh"
  else
    # Caddy reverse-proxies to the live color; publishing is the blue/green swap.
    cp "$SCRIPT_DIR/deploy/site.caddy.tmpl" "$APP_DIR/deploy/site.caddy.tmpl"
    cp "$SCRIPT_DIR/deploy/swap.sh"         "$APP_DIR/deploy/swap.sh"
  fi
}

# Generate release files (Phoenix), enforce DB TLS, drop in the pipeline files.
# Order matters: gen.release BEFORE copying our Dockerfile (it writes its own).
prep_app() {
  if is_zola; then
    # Nothing to compile, no image to build, no release task: a static site's
    # whole pipeline is `zola build` plus a file copy. No Dockerfile and no
    # compose.yaml are written on purpose — this app runs no containers of its
    # own; the only container involved is the droplet's shared Caddy.
    log "preparing site: pipeline files (Zola)"
    mkdir -p "$APP_DIR/.github/workflows" "$APP_DIR/deploy"
    cp "$SCRIPT_DIR/app/.github/workflows/deploy.zola.yml"   "$APP_DIR/.github/workflows/deploy.yml"
    cp "$SCRIPT_DIR/app/.github/workflows/rollback.zola.yml" "$APP_DIR/.github/workflows/rollback.yml"
    copy_deploy_files
    return 0
  fi

  if is_sinatra; then
    log "preparing app: pipeline files (Sinatra)"
    cp "$SCRIPT_DIR/app/Dockerfile.ruby"    "$APP_DIR/Dockerfile"
    cp "$SCRIPT_DIR/app/.dockerignore.ruby" "$APP_DIR/.dockerignore"
    pin_ruby
    mkdir -p "$APP_DIR/.github/workflows" "$APP_DIR/deploy"
    cp "$SCRIPT_DIR/app/.github/workflows/deploy.ruby.yml"   "$APP_DIR/.github/workflows/deploy.yml"
    cp "$SCRIPT_DIR/app/.github/workflows/rollback.ruby.yml" "$APP_DIR/.github/workflows/rollback.yml"
    copy_deploy_files
    # Sinatra is SQLite-only: Litestream sidecar + restore, no TLS to patch.
    cp "$SCRIPT_DIR/deploy/compose.sinatra.yaml" "$APP_DIR/deploy/compose.yaml"
    cp "$SCRIPT_DIR/deploy/litestream.yml"       "$APP_DIR/deploy/litestream.yml"
    return 0
  fi

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
  copy_deploy_files
  if is_sqlite; then
    # SQLite compose carries the Litestream sidecar + restore; no managed DB
    # means no TLS config to patch into runtime.exs.
    cp "$SCRIPT_DIR/deploy/compose.sqlite.yaml" "$APP_DIR/deploy/compose.yaml"
    cp "$SCRIPT_DIR/deploy/litestream.yml"      "$APP_DIR/deploy/litestream.yml"
  else
    cp "$SCRIPT_DIR/deploy/compose.yaml" "$APP_DIR/deploy/"
    "$SCRIPT_DIR/scripts/ensure-db-tls.sh" "$APP_DIR"
  fi
  "$SCRIPT_DIR/scripts/ensure-release-task.sh" "$APP_DIR"
}

# Ensure the app dir is a git repo with a GitHub origin (create private if
# absent), and push an initial commit of the app as-generated. The pipeline
# files land in a SEPARATE commit later (commit_push), so history separates
# "what the generator made" from "what the pipeline wired in".
ensure_repo() {
  ( cd "$APP_DIR"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q -b main
    if git remote get-url origin >/dev/null 2>&1 || gh repo view >/dev/null 2>&1; then
      :
    else
      log "creating private GitHub repo '$APP_NAME'"
      gh repo create "$APP_NAME" --source=. --private --remote=origin
    fi
    if ! git rev-parse HEAD >/dev/null 2>&1; then
      log "initial commit (app as generated)"
      git add -A
      git commit -q -m 'initial commit'
    fi
    git push -q -u origin main
  )
}

# Seed CI secrets/vars. Secrets piped via stdin so ecto:// values aren't mangled.
seed_github() {
  log "seeding GitHub secrets + variables"
  ( cd "$APP_DIR"
    printf '%s' "$DIGITALOCEAN_ACCESS_TOKEN" | gh secret set DIGITALOCEAN_ACCESS_TOKEN
    gh secret set SSH_PRIVATE_KEY < "$SSH_PRIVATE_KEY"
    # Session/signing secret. Phoenix ships a generator; Sinatra reads it as the
    # Rack session secret, so any 64-byte hex works (openssl). A static site has
    # no session, no cookie and no server-side code — it gets no secret at all.
    if is_static; then
      :
    elif is_sinatra; then
      openssl rand -hex 64                     | gh secret set SECRET_KEY_BASE
    else
      mix phx.gen.secret                       | gh secret set SECRET_KEY_BASE
    fi
    # A static site pushes no image, so it needs no registry (and burns no
    # repository against the registry's tier limit).
    is_static || gh variable set DOCR_REGISTRY -b "$REG"
    gh variable set DOMAIN        -b "$DOMAIN"
    gh variable set DROPLET_HOST  -b "$APP_IP"
    gh variable set FIREWALL_ID   -b "$FW_ID"
    # Keeps this app's stack directory, compose project, Caddy site file and
    # network aliases distinct from every other app on the same droplet.
    gh variable set APP_SLUG      -b "$APP_SLUG"
    # deploy.yml branches its .env / file delivery on this.
    gh variable set DATABASE_BACKEND -b "$DATABASE_BACKEND"

    if is_static; then
      # No .env is written for a static site: nothing it ships is secret.
      :
    elif is_sqlite; then
      # SQLite: no DB URL/CA. The Spaces keypair (Litestream replica auth) and the
      # replica target travel as secrets/vars; deploy.yml writes them into .env.
      gh variable set DATABASE_PATH   -b "$DATABASE_PATH"
      printf '%s' "$SPACES_ACCESS_KEY_ID"     | gh secret set LITESTREAM_ACCESS_KEY_ID
      printf '%s' "$SPACES_SECRET_ACCESS_KEY" | gh secret set LITESTREAM_SECRET_ACCESS_KEY
      gh variable set BACKUP_BUCKET   -b "$BACKUP_BUCKET"
      gh variable set BACKUP_ENDPOINT -b "$BACKUP_ENDPOINT"
      gh variable set BACKUP_REGION   -b "$BACKUP_REGION"
      gh variable set BACKUP_PATH     -b "$BACKUP_PATH"
    else
      printf '%s' "$DATABASE_URL"               | gh secret set DATABASE_URL
      printf '%s' "$DATABASE_CA_CERT"           | gh secret set DATABASE_CA_CERT
    fi
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
    printf '\n--- 3. Caddy logs (last 40 lines) — SHARED across every app on this droplet ---\n'
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      root@"$APP_IP" 'cd /root/caddy && docker compose logs --tail 40 caddy' 2>&1 \
      || echo "(caddy logs unavailable — the shared edge stack may not be up yet)"
    printf '\n--- 4. This app'\''s stack (/root/apps/%s) ---\n' "$APP_SLUG"
    # A static site has no containers: what matters is which release `current`
    # points at, and whether the route file exists.
    if is_static; then
      probe="ls -l /root/apps/$APP_SLUG/current; ls -1t /root/apps/$APP_SLUG/releases 2>/dev/null | head -5"
    else
      probe="cd /root/apps/$APP_SLUG && docker compose ps -a"
    fi
    ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      root@"$APP_IP" "$probe; cat /root/caddy/sites/$APP_SLUG.caddy" 2>&1 \
      || echo "(app stack not on the droplet yet — the deploy has not reached it)"
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
    # heartbeat every 60s so a long CI build never reads as a hang
    if [ $((waited % 60)) -eq 0 ] && [ "$waited" -gt 0 ]; then
      log "  still waiting (${waited}s) — CI state: ${state:-no run registered yet}"
    fi
    sleep 10; waited=$((waited + 10))
  done
}

provision() {
  # A tenant skips the five host-only steps and runs three of its own.
  is_tenant && TOTAL_STEPS=14
  log "transcript of this run: $LOG_FILE"
  step "preflight checks";                          preflight
  step "ensure app exists (generate if missing)";   ensure_app
  step "parse app metadata";                        parse_meta
  step "GitHub repo + initial commit";              ensure_repo
  step "sync Terraform roots into the app (infra/)"; sync_infra

  if is_tenant; then
    # Six steps the host already did, and doing them again is either wasteful
    # (a second bucket, a second registry) or actively wrong (a second droplet
    # for an app meant to share one). The tenant adopts them instead.
    step "adopt the host's Terraform state bucket"; adopt_host_state
    step "tenant infra: DNS on the host droplet (infra/tenant)"; tf_tenant
    step "container registry";                      ensure_registry_unless_static
  else
    step "Terraform state bucket (infra/state)";    ensure_state_bucket
    step "persistent infra: VPC/DB/DNS (infra/persistent)"; tf_persistent
    step "container registry";                      ensure_registry_unless_static
    step "detect SSH allow CIDR";                   detect_cidr
    step "app infra: droplet/firewall (infra/app)"; tf_app
  fi

  step "wait for droplet Docker daemon";            wait_droplet_ready
  step "grant DB schema privileges";                grant_db_schema
  step "prepare app: release/TLS/pipeline files";   prep_app
  step "seed GitHub secrets + variables";           seed_github
  step "commit + push pipeline (first deploy)";     commit_push
  step "poll until live";                           confirm_live
  if is_tenant; then
    log "done. app live at https://$DOMAIN | droplet: $APP_IP (shared with $(basename "$HOST_APP_DIR"))"
  else
    log "done. app live at https://$DOMAIN | droplet: $APP_IP"
  fi
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
  local check=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      # Tenant mode: deploy onto the droplet this app already owns. Equivalent
      # to HOST_APP_DIR in the environment; the flag wins.
      --host)
        [ -n "${2:-}" ] || fail "--host needs the host app's directory"
        HOST_APP_DIR="$(abs_dir "$2")"; shift 2 ;;
      --host=*) HOST_APP_DIR="$(abs_dir "${1#--host=}")"; shift ;;
      -*) fail "unknown argument: $1 (use --check, --host <host_app_dir>, or [app_dir])" ;;
      *)  break ;;
    esac
  done

  APP_DIR="$(abs_dir "${1:-.}")"
  [ -z "$HOST_APP_DIR" ] || HOST_APP_DIR="$(abs_dir "$HOST_APP_DIR")"
  set_infra_dirs

  if [ "$check" -eq 1 ]; then
    preflight
    exit 0
  fi
  provision
}

main "$@"
