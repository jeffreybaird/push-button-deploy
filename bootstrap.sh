#!/usr/bin/env bash
#
# bootstrap.sh — push-button stand-up for an app on DigitalOcean.
#
#   ./bootstrap.sh --check [app_dir]   # verify prerequisites, exit non-zero on first gap
#   ./bootstrap.sh [app_dir]           # provision + wire + deploy (default app_dir: .)
#   ./bootstrap.sh --host <host_app_dir> [app_dir]
#                                      # deploy onto a droplet that ALREADY serves
#                                      # <host_app_dir>'s app (a "tenant")
#   ./bootstrap.sh --cli <lang> [app_dir]
#                                      # build a command-line program instead —
#                                      # repo + CI, no droplet and no credentials
#   ./bootstrap.sh --no-droplet [app_dir]
#                                      # build a reusable package the same way
#   ./bootstrap.sh --interactive       # -i: prompt for every choice, then deploy
#   ./bootstrap.sh --help              # the full type + language list
#
# APP TYPES. What gets built is chosen on two axes, both defined in
# scripts/app-types.sh and both listed by --help:
#
#   --service (default)  a web app on its own droplet, served over HTTPS —
#                        everything this script did before the types existed,
#                        unchanged by them.
#   --cli                a command-line program. CI tests it and builds an
#                        executable; nothing is provisioned and nothing served.
#   --no-droplet         a reusable package (alias: --library). CI tests and
#                        builds it; nothing is provisioned and nothing served.
#
# ...and a LANGUAGE within the type — the second axis, and the one that matters
# most for a CLI, whose stacks differ only by it:
#
#   ./bootstrap.sh --cli ruby ~/src/mytool        # or --cli=ruby, or --lang ruby
#   ./bootstrap.sh --cli bash ~/src/mytool
#   ./bootstrap.sh --cli typescript ~/src/mytool
#   ./bootstrap.sh --cli elixir ~/src/mytool      # the default for --cli
#
# EVERY CLI IS A COMMAND, not a script with environment variables in front of
# it. Each scaffold ships real argument parsing over its language's standard
# option parser — `mytool --format json hello`, `--format=json`, short flags,
# `--`, `--help`, `--version`, positional arguments, and exit codes (2 for a
# usage error, so a caller can tell "you typed it wrong" from "it failed"). And
# each is a library with a thin executable on top, so the same code is both
# importable and runnable.
#
# --no-droplet is a CONSTRAINT rather than a type of its own: on its own it
# builds a package, alongside --cli it is already satisfied, and against
# --service it fails rather than half-applying.
#
# The droplet-free types need NO DigitalOcean, DNSimple, Spaces or SSH
# credentials at all — preflight asks for the code host and nothing else,
# because there is nothing else to talk to. Gems, hex packages and OTP apps
# belong under --no-droplet; scripts/app-types.sh says what adding one takes.
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
# PR STAGING: every app with a server-side runtime (i.e. not FRAMEWORK=zola)
# also gets a staging name, <record>-stg.<zone>, pointed at the same droplet.
# Opening a pull request against main stands a complete environment up behind it
# — its own compose project, volumes, database and Caddy route — and closing the
# PR destroys it (.github/workflows/staging.yml). The NAME is Terraform's, so CI
# never needs DNSimple credentials; the ENVIRONMENT is the pipeline's. There is
# one staging slot per app, held by the most recent PR to deploy.
#
# app_dir may be EMPTY or NOT EXIST YET: a fresh app is generated there
# (Phoenix: mix phx.new <basename>; Sinatra: scripts/new-sinatra-app.sh). An
# existing app is used as-is.
#
# Optional config (env, with defaults):
#   APP_TYPE          'service' (default), 'cli' or 'library' — the same choice
#                     the flags above make, for a .env. See scripts/app-types.sh.
#   LANGUAGE          the language within the app type — the same choice --lang
#                     and `--cli <lang>` make. service: 'elixir' (default),
#                     'ruby' or 'static'. cli: 'elixir' (default), 'ruby',
#                     'bash' or 'typescript'. library: 'elixir'.
#   FRAMEWORK         the stack within the app type, by its own name rather than
#                     its language; unique across types, so naming one alone also
#                     picks the type. service: 'phoenix' (default), 'sinatra' or
#                     'zola'. 'sinatra' is SQLite-only and forces
#                     DATABASE_BACKEND=sqlite; 'zola' is a STATIC site with no
#                     database at all (DATABASE_BACKEND=none) and no container
#                     image. cli: 'escript' (default), 'ruby-cli', 'bash-cli' or
#                     'ts-cli'. library: 'mix'. Everything outside 'service' is
#                     droplet-free with no data layer of any kind. Chosen once
#                     per project.
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
#   ENABLE_STAGING 'true' (default) gives the app a PR staging environment at
#                  <DNS_RECORD>-stg.<DNS_ZONE>; 'false' provisions none. Always
#                  false for a static site.
#   SSH_CIDRS      JSON list for SSH allow, e.g. ["1.2.3.4/32"]. Default: auto-detected public IP /32.
#   DOCR_REGISTRY  name for a new DO registry if none exists. Default: PROJECT_NAME.
#   STATE_BUCKET   Spaces bucket for Terraform state. Default: <PROJECT_NAME>-tfstate.
#   SPACES_REGION  region for the state bucket (must offer Spaces). Default: REGION.
#   GIT_PROVIDER   'github' (default) or 'gitea' (self-hosted). See GITEA_* below.
#     GITEA_URL         base URL of the instance, e.g. https://git.example.com.
#                       Required when GIT_PROVIDER=gitea.
#     GITEA_TOKEN       personal access token (repo create/delete, Actions
#                       secrets/variables). Required when GIT_PROVIDER=gitea.
#     GITEA_OWNER       user or org the repo is created under. Optional — unset,
#                       it's whichever account GITEA_TOKEN authenticates as (the
#                       same implicit-current-user behavior `gh` gives GitHub).
#     GITEA_RUNNER_IP   stable IP/CIDR of the self-hosted Actions runner,
#                       allow-listed once in Terraform (infra-app/firewall.tf)
#                       instead of the GitHub path's per-run firewall punch.
#                       Required when GIT_PROVIDER=gitea.
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
#   DIGITALOCEAN_ACCESS_TOKEN   DO API token (terraform, doctl, DOCR, CI secret)
#   DNSIMPLE_TOKEN              DNSimple API token (terraform)
#   DNSIMPLE_ACCOUNT           DNSimple account id (terraform)
#   DNS_ZONE                   apex zone, e.g. lennonbaird.com
#   SSH_KEY_NAME               name of an SSH key already uploaded to DO
#   SSH_PRIVATE_KEY            path to the matching private key (becomes a CI secret)
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

# PR STAGING ENVIRONMENTS. Every dynamic app gets a second name on the same
# droplet, <record>-stg.<zone>, behind which a pull request against main stands
# up a complete copy of itself — its own compose project, volumes, database and
# Caddy route — torn down when the PR closes (.github/workflows/staging.yml,
# deploy/staging-down.sh). A static site is excluded: there is no environment to
# build, only files a symlink points at.
#
# The NAME is Terraform's (infra/persistent, or infra/tenant), so CI never needs
# DNSimple credentials; the ENVIRONMENT is the pipeline's. STAGING_DOMAIN is read
# back from Terraform after the apply and is empty when staging is off — which is
# also what an app whose infra/ copy predates this feature reads as, so it simply
# keeps deploying production and nothing breaks.
#
# GITHUB ONLY, for now: the staging workflow exists as a template under
# app/.github/workflows/ and has no app/.gitea/workflows/ counterpart, so a Gitea
# app has nothing to run a PR environment WITH. Provisioning the staging name and
# database anyway would bill for a DNS record and a database no pipeline ever
# touches, so the whole feature is off on that path until the workflow is ported.
# needs_droplet, not just "not static": a CLI or a library has no environment to
# stand up behind a pull request, and no droplet to stand it up on.
wants_staging()   { [ "${ENABLE_STAGING:-true}" = true ] && needs_droplet && ! is_static && is_github; }
staging_enabled() { [ -n "${STAGING_DOMAIN:-}" ]; }

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

# Code-hosting + CI/CD provider selector. 'github' (default) drives every step
# with the `gh` CLI and GitHub Actions, unchanged. 'gitea' talks to a
# self-hosted Gitea instance's REST API instead (scripts/provider.sh, sourced
# below after .env — same reasoning as FRAMEWORK/DATABASE_BACKEND: it applies
# a default/coercion, so it must not resolve before a .env value could win).
# is_github/is_gitea are defined there, next to the resolution.

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

# The app-type + framework registry (APP_TYPE/FRAMEWORK resolution, the
# capability predicates every droplet-free branch below is gated on, and the
# tables that make adding a gem/hex/OTP type a data change). Sourced HERE, after
# .env, for the same reason provider.sh is: it applies defaults and coercions,
# and resolving before .env could let a .env value outrank one.
# shellcheck source=scripts/app-types.sh
. "$SCRIPT_DIR/scripts/app-types.sh"

# shellcheck source=scripts/provider.sh
. "$SCRIPT_DIR/scripts/provider.sh"

# Everything that DEPENDS on the resolved app type — which is only known after
# main() has parsed the flags, hence a function rather than top-level lines.
# Nothing above this point reads FRAMEWORK, DATABASE_BACKEND or REQUIRED_* at
# load time; the is_* predicates only read them when called.
resolve_app_config() {
  # APP_TYPE first: it decides which frameworks are legal, and FRAMEWORK
  # (possibly from .env) decides the type when no flag named one.
  resolve_app_type

  DATABASE_BACKEND="${DATABASE_BACKEND:-sqlite}"
  # Sinatra runs on SQLite only (Sequel + Litestream); a static site has no data
  # layer at all, and neither does anything droplet-free — a CLI and a library
  # have nowhere to keep a database and nothing that would talk to one. All are
  # FORCED rather than refused, because the common case is a shared .env carrying
  # a DATABASE_BACKEND meant for some other project, and failing there would be
  # obstructive. But an override that changes what gets provisioned is never
  # silent: say so when the incoming value actually differed.
  local requested_backend="${DATABASE_BACKEND}"
  if is_sinatra;      then DATABASE_BACKEND="sqlite"; fi
  if is_zola;         then DATABASE_BACKEND="none"; fi
  if ! has_database;  then DATABASE_BACKEND="none"; fi
  # Only 'postgres' is worth a warning: it is the one request whose silent
  # downgrade would change what gets provisioned, billed and backed up. Ignoring
  # a 'sqlite' on a static site provisions nothing either way, and a shared .env
  # naming it is the normal case — warning there would be noise on every run.
  if [ "$requested_backend" = "postgres" ] && [ "$DATABASE_BACKEND" != "postgres" ]; then
    warn "$APP_TYPE/$FRAMEWORK forces DATABASE_BACKEND=$DATABASE_BACKEND — the requested managed Postgres cluster will NOT be provisioned"
  fi

  # PR staging environments, on by default for anything with a server-side
  # runtime. Turning it off here removes the staging DNS record (and, on
  # Postgres, the staging database) on the next apply; the workflow shipped with
  # the app then finds no STAGING_DOMAIN variable and skips every job.
  ENABLE_STAGING="${ENABLE_STAGING:-true}"
  case "$ENABLE_STAGING" in
    true|false) ;;
    *) fail "ENABLE_STAGING must be 'true' or 'false' (got '$ENABLE_STAGING')" ;;
  esac

  # Staging has no Gitea workflow yet (see wants_staging). Silently dropping an
  # explicit request for it would be the one case where the user is owed a word
  # — but only where staging was ever on the table: a droplet-free app has no
  # environment to stand up in the first place.
  if [ "$ENABLE_STAGING" = true ] && needs_droplet && ! is_static && is_gitea; then
    warn "GIT_PROVIDER=gitea has no staging workflow yet — no PR environment will be built, and no staging DNS name or database will be provisioned"
  fi

  # Local tooling, by capability rather than by name. A droplet-free app talks to
  # the code host and nothing else, so it needs neither the DigitalOcean CLI nor
  # Terraform nor an SSH client — and its scaffolds are pure bash, so it does not
  # even need a local Elixir.
  REQUIRED_BINS="git curl"
  if needs_droplet; then REQUIRED_BINS="$REQUIRED_BINS terraform doctl ssh scp dig"; fi
  # Framework-specific local tooling: Phoenix generates + prepares the app with
  # `mix`; Sinatra scaffolds with bash and only needs `openssl` (fresh session
  # secret) — the Ruby build itself happens in Docker/CI, not locally. Zola and
  # the droplet-free frameworks add nothing: their scaffolds are written by hand
  # and their builds run in CI.
  if is_sinatra; then REQUIRED_BINS="$REQUIRED_BINS openssl"
  elif is_phoenix; then REQUIRED_BINS="$REQUIRED_BINS mix"; fi
  # gh drives the GitHub path end to end; the Gitea path talks REST over curl
  # (already required) and leans on jq for safe JSON bodies + run-status parsing.
  if is_github; then REQUIRED_BINS="$REQUIRED_BINS gh"
  elif is_gitea; then REQUIRED_BINS="$REQUIRED_BINS jq"; fi

  # Same rule for credentials: what is never contacted is never demanded. This
  # is what lets `./bootstrap.sh --cli ~/src/tool` run on a machine that has
  # never heard of DigitalOcean.
  REQUIRED_ENV=""
  if needs_droplet; then
    REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"
  fi
  # GITEA_OWNER is deliberately NOT required: unset, the repo is created under
  # whichever account GITEA_TOKEN authenticates as (see ci_auth_check) — the same
  # implicit-current-user behavior gh already gives the GitHub path.
  if is_gitea; then
    REQUIRED_ENV="$REQUIRED_ENV GITEA_URL GITEA_TOKEN"
    # The runner IP exists to be allow-listed in the droplet firewall. No
    # droplet, no firewall, nothing to allow-list.
    needs_droplet && REQUIRED_ENV="$REQUIRED_ENV GITEA_RUNNER_IP"
  fi

  # A droplet-free run has eight steps: it skips every provisioning step and
  # replaces "poll until live" with "poll until CI concludes".
  needs_droplet || TOTAL_STEPS=8
}

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

# ---- story 6.1: preflight ----------------------------------------------------
# Checks run in order and fail fast, naming the FIRST gap (AC 6.1).
preflight() {
  local b v val

  case "$DATABASE_BACKEND" in
    postgres|sqlite)
      has_database \
        || fail "DATABASE_BACKEND=$DATABASE_BACKEND is meaningless for a '$APP_TYPE' — it has no data layer and no host to keep one on" ;;
    # 'none' is never selectable by hand: it is what FRAMEWORK=zola and every
    # droplet-free type imply, and the coercion in resolve_app_config is the only
    # thing that sets it.
    none) is_zola || ! has_database \
        || fail "DATABASE_BACKEND=none is only valid for FRAMEWORK=zola" ;;
    *) fail "DATABASE_BACKEND must be 'postgres' or 'sqlite' (got '$DATABASE_BACKEND')" ;;
  esac

  # Tenant mode: the host must be a real, already-bootstrapped app directory —
  # the tenant reads its Terraform state for the droplet's IP and firewall, so a
  # host that was never applied has nothing to read.
  if is_tenant; then
    # Sharing a droplet presupposes needing one. A CLI or a library is not
    # deployed anywhere, so there is nothing for a host to host.
    needs_droplet \
      || fail "--host is for apps that run on a droplet; a '$APP_TYPE' is not deployed to one (nothing would be shared)"
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
  # Nothing to guard where no Terraform runs.
  local dir f
  if needs_droplet; then
    for dir in "$TPL_PERS_DIR" "$TPL_APP_TF_DIR" "$TPL_STATE_TF_DIR" "$TPL_TENANT_TF_DIR" \
               "$PERS_DIR" "$APP_TF_DIR" "$STATE_TF_DIR" "$TENANT_TF_DIR"; do
      for f in "$dir"/terraform.tfvars "$dir"/terraform.tfvars.json "$dir"/*.auto.tfvars "$dir"/*.auto.tfvars.json; do
        [ -e "$f" ] && fail "$f would override bootstrap's variables (terraform precedence: tfvars beats TF_VAR_ env). Move it aside: mv '$f' '$f.bak'"
      done
    done
  fi

  for v in $REQUIRED_ENV; do
    eval "val=\${$v:-}"
    [ -n "$val" ] || fail "missing env var: $v"
  done

  if needs_droplet; then
    [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"
  fi

  # Generating a Phoenix app (only when the target has none) needs the phx_new
  # archive. The Sinatra scaffold is pure bash — nothing extra to check.
  if is_phoenix && [ ! -f "$APP_DIR/mix.exs" ]; then
    mix phx.new --version >/dev/null 2>&1 \
      || fail "no app at $APP_DIR, and the phx_new archive is missing — run: mix archive.install hex phx_new"
  fi

  # The code host is the ONLY thing a droplet-free app talks to, so it is the
  # only credential check that always runs.
  ci_auth_check

  if needs_droplet; then
    doctl account get >/dev/null 2>&1 \
      || fail "doctl not authenticated — run: doctl auth init"

    # The SSH key the droplet will trust must already exist in the DO account.
    # Capture the listing first: a transient API failure must not masquerade as
    # "key not found".
    local ssh_keys
    ssh_keys="$(doctl compute ssh-key list --no-header --format Name)" \
      || fail "doctl compute ssh-key list failed (API error above) — retry"
    printf '%s\n' "$ssh_keys" | grep -qx "$SSH_KEY_NAME" \
      || fail "SSH key '$SSH_KEY_NAME' not found in DO account (doctl compute ssh-key list)"
  fi

  echo "preflight: OK — all prerequisites present ($APP_TYPE/$FRAMEWORK, $LANGUAGE)."
}

# ---- story 6.2: provision + wire + first deploy ------------------------------

# Generate the app when the target directory is empty or missing — this is the
# "empty directory -> deployed app" entry point. An existing app (detected by its
# framework signature file) is used as-is; a non-empty non-app directory is
# refused rather than generated over.
ensure_app() {
  local sig scaffold
  # Both questions — "is an app already here?" and "what generates one?" — are
  # answered by the stack's registry row, so a stack added later needs no branch
  # here. The row is keyed on the (type, framework) pair: a Ruby CLI and a Ruby
  # web app are different rows, and only the pair tells them apart.
  sig="$(framework_signature "$APP_TYPE" "$FRAMEWORK")"
  [ -n "$sig" ] || fail "no signature file registered for $APP_TYPE/$FRAMEWORK (scripts/app-types.sh)"
  # `<name>` in a signature is the app directory's basename — for stacks whose
  # entry point is named after the app (bash: bin/<name>).
  case "$sig" in *'<name>'*) sig="${sig%%<name>*}$(basename "$APP_DIR")${sig#*<name>}" ;; esac
  if [ -f "$APP_DIR/$sig" ]; then
    log "app: using existing $APP_DIR"
    return 0
  fi
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR")" ]; then
    fail "$APP_DIR is not empty and has no $sig — refusing to generate over it"
  fi

  # The row holds the scaffold as `script [args...]`; the app directory is
  # always the last argument. Sinatra and Zola scaffold themselves in pure bash
  # (their builds happen in CI), and so do the droplet-free Elixir types.
  scaffold="$(framework_scaffold "$APP_TYPE" "$FRAMEWORK")"
  if [ "$scaffold" != "-" ]; then
    # Deliberate word splitting: the row's args are shell words, not one string.
    # shellcheck disable=SC2086
    set -- $scaffold
    local generator="$1"; shift
    [ -x "$SCRIPT_DIR/scripts/$generator" ] \
      || fail "scripts/$generator is missing or not executable (scripts/app-types.sh names it for $APP_TYPE/$FRAMEWORK)"
    "$SCRIPT_DIR/scripts/$generator" "$@" "$APP_DIR"
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

# Parse APP_NAME / APP_MODULE (single source of truth).
#
# Keyed on the stack's LANGUAGE, not its framework: what the name is parsed from
# is a property of the language, and every stack of one language answers it the
# same way. Phoenix, an escript and a mix library all declare their name in
# mix.exs; Sinatra and a Ruby CLI both take it from the directory and camelize
# it; a Zola site, a bash CLI and a TypeScript CLI derive no identifier at all,
# so the directory name is the whole answer. Adding a language means adding an
# arm here only if it answers differently from all three.
parse_meta() {
  local sig
  sig="$(framework_signature "$APP_TYPE" "$FRAMEWORK")"
  case "$sig" in *'<name>'*) sig="${sig%%<name>*}$(basename "$APP_DIR")${sig#*<name>}" ;; esac
  [ -f "$APP_DIR/$sig" ] || fail "no $sig in $APP_DIR — generation failed?"

  case "$LANGUAGE" in
    elixir)
      # shellcheck source=scripts/app-meta.sh
      . "$SCRIPT_DIR/scripts/app-meta.sh"
      APP_NAME="$(app_name "$APP_DIR")"
      APP_MODULE="$(app_module "$APP_DIR")" ;;
    ruby)
      APP_NAME="$(basename "$APP_DIR")"
      case "$APP_NAME" in
        [a-z]*[!a-z0-9_]*|*[!a-z0-9_]*|[!a-z]*)
          fail "Ruby app name '$APP_NAME' must be lower_snake_case (the dir basename names the app, its module and its infra)" ;;
      esac
      APP_MODULE="$(printf '%s' "$APP_NAME" | awk -F_ '{o=""; for(i=1;i<=NF;i++){o=o toupper(substr($i,1,1)) substr($i,2)} print o}')" ;;
    *)
      APP_NAME="$(basename "$APP_DIR")"
      case "$APP_NAME" in
        # Hyphens are allowed here where they are not above: nothing derives an
        # Elixir atom or a Ruby module from these names, and a hyphen is the
        # natural spelling for both a domain label and a command.
        [a-z]*[!a-z0-9_-]*|*[!a-z0-9_-]*|[!a-z]*)
          fail "name '$APP_NAME' must be lowercase letters, digits, '_' or '-' (start with a letter): the dir basename names it" ;;
      esac
      # Nothing evaluates a module for these; carried only so the log line and
      # downstream references have a value.
      APP_MODULE="(no module: $LANGUAGE)" ;;
  esac
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
  if needs_droplet; then
    log "app: $APP_NAME ($APP_MODULE) [$APP_TYPE/$FRAMEWORK, $LANGUAGE] | project: $PROJECT_NAME | region: $REGION"
  else
    # PROJECT_NAME/REGION/DNS_RECORD are still resolved above so nothing
    # downstream has to special-case an unset variable, but none of them names
    # anything on this path: no bucket, no cluster, no DNS record exists to name.
    log "app: $APP_NAME ($APP_MODULE) [$APP_TYPE/$FRAMEWORK, $LANGUAGE] — repo + CI only, no infrastructure"
  fi
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

# Spaces state-bucket bootstrap (ensure_state_bucket, bucket_visible,
# wait_bucket_visible, backend_init) — factored into scripts/tfstate.sh so
# bootstrap-gitea.sh can share it rather than duplicate the fallback-creation
# logic (see that file's header comment for why it's worth sharing).
# shellcheck source=scripts/tfstate.sh
. "$SCRIPT_DIR/scripts/tfstate.sh"

# Read the staging outputs back from a root that was just applied.
#
#   $1  the app's root directory (infra/persistent or infra/tenant)
#   $2  this repo's matching template, named in the hint below
#
# They are ABSENT — not empty — in an app whose infra/ copy predates staging:
# sync-infra seeds each file once and never overwrites it, so an existing app
# keeps its old dns.tf until someone adopts the new one. `output -raw` on a
# missing output exits non-zero, so every read here tolerates failure and an
# empty STAGING_DOMAIN means one thing everywhere: this app has no staging
# environment, wire none.
read_staging_outputs() {
  local root="$1" template="$2"
  STAGING_DOMAIN="$(terraform -chdir="$root" output -raw staging_domain 2>/dev/null || true)"
  STAGING_DATABASE_URL=""

  if staging_enabled; then
    if ! is_sqlite && ! is_static; then
      STAGING_DATABASE_URL="$(terraform -chdir="$root" output -raw database_staging_url 2>/dev/null || true)"
      [ -n "$STAGING_DATABASE_URL" ] \
        || fail "staging is on but the root produced no database_staging_url — adopt the current $template/database.tf and outputs.tf, or set enable_staging = false"
    fi
    log "staging: pull requests against main will serve on https://$STAGING_DOMAIN"
    # if/fi rather than `[ … ] && log`: a false test here would be the last
    # command in the function, and set -e would take the whole run down with it.
    if [ -n "$STAGING_DATABASE_URL" ]; then
      log "staging: uses database '${PROJECT_NAME}-staging' on the app's EXISTING Postgres cluster — no second instance"
    fi
  elif wants_staging; then
    warn "no staging_domain output in $root — this app's infra copy predates PR staging environments.
     Production is unaffected; to enable them, adopt the current templates:
       diff -ru $template $root"
  fi
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
  export TF_VAR_state_bucket_name="$STATE_BUCKET"
  # The staging NAME (and, on Postgres, the staging database). Off for a static
  # site. An infra/persistent copy that predates staging simply ignores this.
  if wants_staging; then export TF_VAR_enable_staging=true; else export TF_VAR_enable_staging=false; fi

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
  read_staging_outputs "$PERS_DIR" "$TPL_PERS_DIR"
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
  # A tenant's staging environment is another compose project on the same shared
  # droplet — one more name pointed at the host's IP.
  if wants_staging; then export TF_VAR_enable_staging=true; else export TF_VAR_enable_staging=false; fi

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
  read_staging_outputs "$TENANT_TF_DIR" "$TPL_TENANT_TF_DIR"

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

# A DO registry caps how many REPOSITORIES it may hold, by subscription tier
# (starter 1, basic 5, professional unlimited). One app = one repository, so an
# account at its cap cannot take a new app — and nothing says so until the CI
# build tries to push, six minutes and a whole droplet later, failing with an
# opaque `denied: registry contains 5 repositories, limit is 5` buried in the
# Actions log. The quota is knowable here, so check it here.
#
# Tolerant by design: an API hiccup, an unparseable body or an empty listing
# must not block a bootstrap that would otherwise work. Only a definite
# over-cap answer fails.
check_registry_quota() {
  local limit used
  limit="$(curl -fsS -H "Authorization: Bearer $DIGITALOCEAN_ACCESS_TOKEN" \
             https://api.digitalocean.com/v2/registry/subscription 2>/dev/null \
           | sed -n 's/.*"included_repositories":[[:space:]]*\([0-9]*\).*/\1/p')"
  # No answer, or 0 — which the API uses for "unlimited" on the professional
  # tier, not for "no repositories allowed".
  [ -n "$limit" ] && [ "$limit" -gt 0 ] 2>/dev/null || return 0

  # `list-v2` honours neither --format nor --no-header, so the name column is
  # cut by hand and the header row dropped — counting it would report one
  # repository more than exist, and comparing against a whole row would never
  # match this app's name.
  local repos
  repos="$(doctl registry repository list-v2 2>/dev/null | awk 'NR>1 {print $1}')" || return 0
  # This app's own repository already exists: redeploying it takes no new slot,
  # so a registry that is exactly full is still fine. The repository is named
  # after .app-name (APP_NAME), which is what the build job pushes to.
  printf '%s\n' "$repos" | grep -qx "$APP_NAME" && return 0

  used="$(printf '%s\n' "$repos" | grep -c . || true)"
  [ "$used" -ge "$limit" ] || return 0

  fail "container registry '$REG' is full: $used of $limit repositories on this tier, and '$APP_NAME' would be one more.
      The CI build would fail with 'denied: registry contains $used repositories, limit is $limit'.
      Free a slot (delete EVERY manifest of a repository — deleting only its tags leaves the
      repository, and the slot, in place):
        doctl registry repository list-v2
        doctl registry repository list-manifests <repo>
        doctl registry repository delete-manifest <repo> <digest>...
      Deletes are rejected while a garbage collection is running; check with
      'doctl registry garbage-collection get-active'. Or raise the cap:
        doctl registry options subscription-tiers"
}

# Ensure a DO Container Registry exists; capture its name.
ensure_registry() {
  if doctl registry get --format Name --no-header >/dev/null 2>&1; then
    REG="$(doctl registry get --format Name --no-header)"
    log "registry: using existing '$REG'"
    check_registry_quota
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
# GITEA_RUNNER_IP -> the JSON list infra-app/firewall.tf wants. Accepts a
# comma-separated list, because "the runner's IP" is not always one address: a
# second runner, or a droplet reconfigured to egress over its reserved IP
# (which is NOT the default — see infra-gitea/outputs.tf gitea_egress_ip),
# both need more than one entry. A bare address is treated as a /32 rather
# than rejected: `1.2.3.4` is what people type, and silently emitting invalid
# HCL for it would surface as a confusing Terraform error instead.
# Empty (or GitHub) yields [], which firewall.tf's `dynamic` block reads as
# "add no rule at all".
gitea_runner_cidr_json() {
  is_gitea || { printf '[]'; return 0; }
  local out="" entry
  local IFS=,
  for entry in $GITEA_RUNNER_IP; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    case "$entry" in *[!0-9./]*) fail "GITEA_RUNNER_IP has a non-IPv4 entry: '$entry' (expected e.g. 203.0.113.9 or 203.0.113.9/32, comma-separated for more than one)" ;; esac
    case "$entry" in *"/"*) ;; *) entry="$entry/32" ;; esac
    out="$out${out:+,}\"$entry\""
  done
  printf '[%s]' "$out"
}

tf_app() {
  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_ssh_key_name="$SSH_KEY_NAME"
  export TF_VAR_ssh_cidrs="$SSH_CIDRS_JSON"
  export TF_VAR_state_bucket="$STATE_BUCKET"
  export TF_VAR_state_endpoint="$STATE_ENDPOINT"
  # Gitea's self-hosted Actions runner has a stable IP: allow-list it here,
  # once, rather than punching a per-run firewall hole the way the GitHub-
  # hosted-runner path does (see app/.gitea/workflows/*.yml). Empty on the
  # GitHub path — zero behavior change for existing deploys.
  export TF_VAR_gitea_runner_cidr="$(gitea_runner_cidr_json)"

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

  # The staging database is a second database in the same cluster and needs the
  # same grant, or the first PR environment's first migration dies on
  # insufficient_privilege. Same route (through the droplet), same statement.
  staging_enabled || return 0
  local staging_admin_url
  staging_admin_url="$(terraform -chdir="$PERS_DIR" output -raw database_staging_admin_url 2>/dev/null || true)"
  [ -n "$staging_admin_url" ] || return 0
  log "granting schema public privileges on the staging database (via droplet)"
  quiet ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new root@"$APP_IP" \
    "docker run --rm postgres:17-alpine psql '$staging_admin_url' -v ON_ERROR_STOP=1 \
       -c 'GRANT ALL ON SCHEMA public TO \"$PROJECT_NAME\";'"
  log "staging schema grant applied"
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
    # Tears a PR staging environment off the droplet. Travels with every dynamic
    # app for the same reason edge.sh does: the workflow that needs it ships it.
    cp "$SCRIPT_DIR/deploy/staging-down.sh" "$APP_DIR/deploy/staging-down.sh"
  fi
}

# The staging environment's two SQLITE-ONLY files. They are what keep a pull
# request away from production's backups: replication goes to a path inside the
# environment's own volume, and the archive-to-Spaces loop is switched off. The
# Postgres stack needs neither — it has no such services, and its staging
# isolation is a separate database in the same cluster.
# Copy the staging workflow, but only from a template set that HAS one. Keeps
# prep_app's two call sites identical across providers instead of making each of
# them re-derive which provider ships what.
copy_staging_workflow() { # $1 template basename, $2 template dir, $3 dest dir
  local tpl="$SCRIPT_DIR/$2/$1"
  wants_staging || return 0
  [ -f "$tpl" ] || return 0
  cp "$tpl" "$APP_DIR/$3/staging.yml"
}

copy_staging_files() {
  wants_staging || return 0
  cp "$SCRIPT_DIR/deploy/compose.staging.yaml"   "$APP_DIR/deploy/compose.staging.yaml"
  cp "$SCRIPT_DIR/deploy/litestream.staging.yml" "$APP_DIR/deploy/litestream.staging.yml"
}

# Copy the framework's workflows out of the provider's template set. The
# registry names them as `src:dest` pairs — src is the template's basename (they
# are suffixed per framework: deploy.ruby.yml, ci.escript.yml), dest is what the
# app repo calls it (deploy.yml, ci.yml). Keeping the mapping in the table is
# what lets a new framework ship a pipeline without an edit here.
copy_workflows() { # $1 template dir (repo-relative), $2 dest dir (app-relative)
  local pair src dst
  for pair in $(framework_workflows "$APP_TYPE" "$FRAMEWORK"); do
    src="${pair%%:*}"; dst="${pair##*:}"
    [ -f "$SCRIPT_DIR/$1/$src" ] \
      || fail "no workflow template $1/$src — $APP_TYPE/$FRAMEWORK names it in scripts/app-types.sh, but this provider does not ship one"
    cp "$SCRIPT_DIR/$1/$src" "$APP_DIR/$2/$dst"
  done
}

# Generate release files (Phoenix), enforce DB TLS, drop in the pipeline files.
# Order matters: gen.release BEFORE copying our Dockerfile (it writes its own).
prep_app() {
  # Workflow files live at .github/workflows/ for GitHub Actions or
  # .gitea/workflows/ for Gitea Actions — same destination BASENAME either way
  # (deploy.yml/rollback.yml), just a different directory and a different
  # source template set (app/.gitea/workflows/ drops the GitHub-runner-specific
  # firewall hole-punch steps; see that directory's README note).
  local wf_dir tpl_wf_dir
  if is_gitea; then wf_dir=".gitea/workflows"; tpl_wf_dir="app/.gitea/workflows"
  else              wf_dir=".github/workflows"; tpl_wf_dir="app/.github/workflows"; fi

  # The app records what it is. teardown.sh reads this to know a droplet-free
  # project has nothing to destroy, instead of inferring it from which files
  # happen to be lying around.
  printf '%s\n' "$APP_TYPE" > "$APP_DIR/.app-type"

  if ! needs_droplet; then
    # A CLI or a library gets its CI workflow and nothing else: no Dockerfile,
    # no compose file, no deploy/ directory, no release task, no TLS to patch,
    # no edge proxy. The workflow the registry names IS the whole pipeline.
    log "preparing $APP_TYPE ($LANGUAGE): CI workflow only (nothing is deployed anywhere)"
    mkdir -p "$APP_DIR/$wf_dir"
    copy_workflows "$tpl_wf_dir" "$wf_dir"
    return 0
  fi

  if is_zola; then
    # Nothing to compile, no image to build, no release task: a static site's
    # whole pipeline is `zola build` plus a file copy. No Dockerfile and no
    # compose.yaml are written on purpose — this app runs no containers of its
    # own; the only container involved is the droplet's shared Caddy.
    log "preparing site: pipeline files (Zola)"
    mkdir -p "$APP_DIR/$wf_dir" "$APP_DIR/deploy"
    copy_workflows "$tpl_wf_dir" "$wf_dir"
    copy_deploy_files
    return 0
  fi

  if is_sinatra; then
    log "preparing app: pipeline files (Sinatra)"
    cp "$SCRIPT_DIR/app/Dockerfile.ruby"    "$APP_DIR/Dockerfile"
    cp "$SCRIPT_DIR/app/.dockerignore.ruby" "$APP_DIR/.dockerignore"
    pin_ruby
    mkdir -p "$APP_DIR/$wf_dir" "$APP_DIR/deploy"
    copy_workflows "$tpl_wf_dir" "$wf_dir"
    copy_staging_workflow staging.ruby.yml "$tpl_wf_dir" "$wf_dir"
    copy_deploy_files
    # Sinatra is SQLite-only: Litestream sidecar + restore, no TLS to patch.
    cp "$SCRIPT_DIR/deploy/compose.sinatra.yaml" "$APP_DIR/deploy/compose.yaml"
    cp "$SCRIPT_DIR/deploy/litestream.yml"       "$APP_DIR/deploy/litestream.yml"
    copy_staging_files
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
  mkdir -p "$APP_DIR/$wf_dir" "$APP_DIR/deploy"
  copy_workflows "$tpl_wf_dir" "$wf_dir"
  copy_staging_workflow staging.yml "$tpl_wf_dir" "$wf_dir"
  copy_deploy_files
  if is_sqlite; then
    # SQLite compose carries the Litestream sidecar + restore; no managed DB
    # means no TLS config to patch into runtime.exs.
    cp "$SCRIPT_DIR/deploy/compose.sqlite.yaml" "$APP_DIR/deploy/compose.yaml"
    cp "$SCRIPT_DIR/deploy/litestream.yml"      "$APP_DIR/deploy/litestream.yml"
    copy_staging_files
  else
    cp "$SCRIPT_DIR/deploy/compose.yaml" "$APP_DIR/deploy/"
    "$SCRIPT_DIR/scripts/ensure-db-tls.sh" "$APP_DIR"
  fi
  "$SCRIPT_DIR/scripts/ensure-release-task.sh" "$APP_DIR"
}

# Ensure the app dir is a git repo with a code-host origin (create private if
# absent), and push an initial commit of the app as-generated. The pipeline
# files land in a SEPARATE commit later (commit_push), so history separates
# "what the generator made" from "what the pipeline wired in".
ensure_repo() {
  ( cd "$APP_DIR"
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || git init -q -b main

    # Ask the PROVIDER whether the repo exists — never the local remote. An
    # origin outlives the repo it points at (deleted by hand, or the whole
    # instance rebuilt), so treating "origin is configured" as proof of
    # existence skipped creation and left the push below to die on a 404.
    if repo_exists; then
      log "repo '$APP_NAME' already exists on the code host"
    else
      # Any origin at this point references something that is gone: stale by
      # definition. Drop it so repo_create can wire a correct one.
      if git remote get-url origin >/dev/null 2>&1; then
        warn "origin points at a repo that no longer exists — recreating it"
        git remote remove origin
      fi
      log "creating private $( is_gitea && printf Gitea || printf GitHub ) repo '$APP_NAME'"
      repo_create
    fi

    # repo_create wires origin, but only on the path where it did the
    # creating. A repo that already existed while the local remote did not
    # (fresh directory, or a hand-run `git remote remove origin`) needs one.
    if ! git remote get-url origin >/dev/null 2>&1; then
      remote_url="$(repo_remote_url)"
      [ -n "$remote_url" ] \
        || fail "repo '$APP_NAME' exists on the code host but its clone URL could not be determined"
      log "wiring origin -> $remote_url"
      git remote add origin "$remote_url"
    fi
    if ! git rev-parse HEAD >/dev/null 2>&1; then
      log "initial commit (app as generated)"
      git add -A
      git commit -q -m 'initial commit'
    fi
    provider_git_push -q -u origin main
  )
}

# Seed CI secrets/vars. Secrets piped via stdin so ecto:// values aren't mangled.
seed_ci() {
  if ! needs_droplet; then
    # Every secret and variable below names a piece of infrastructure — a
    # registry, a droplet, a firewall, a database, a replica bucket. A
    # droplet-free pipeline references none of them, so seeding any would be
    # config nobody reads. This is the step's whole job here: say so, and add
    # nothing to the repo.
    log "no droplet: nothing to seed (this pipeline reads no secrets or variables)"
    return 0
  fi
  log "seeding CI secrets + variables"
  ( cd "$APP_DIR"
    printf '%s' "$DIGITALOCEAN_ACCESS_TOKEN" | secret_set DIGITALOCEAN_ACCESS_TOKEN
    secret_set SSH_PRIVATE_KEY < "$SSH_PRIVATE_KEY"
    # Session/signing secret. Phoenix ships a generator; Sinatra reads it as the
    # Rack session secret, so any 64-byte hex works (openssl). A static site has
    # no session, no cookie and no server-side code — it gets no secret at all.
    if is_static; then
      :
    elif is_sinatra; then
      openssl rand -hex 64                     | secret_set SECRET_KEY_BASE
    else
      mix phx.gen.secret                       | secret_set SECRET_KEY_BASE
    fi
    # A static site pushes no image, so it needs no registry (and burns no
    # repository against the registry's tier limit).
    is_static || var_set DOCR_REGISTRY "$REG"
    var_set DOMAIN        "$DOMAIN"
    var_set DROPLET_HOST  "$APP_IP"
    # Gitea's runner IP is statically allow-listed in Terraform
    # (infra-app/firewall.tf, gitea_runner_cidr) instead of punched per-run, so
    # the Gitea workflow templates never reference FIREWALL_ID — seeding it
    # would just be unused config.
    is_gitea || var_set FIREWALL_ID "$FW_ID"
    # Keeps this app's stack directory, compose project, Caddy site file and
    # network aliases distinct from every other app on the same droplet.
    var_set APP_SLUG      "$APP_SLUG"
    # deploy.yml branches its .env / file delivery on this.
    var_set DATABASE_BACKEND "$DATABASE_BACKEND"

    if is_static; then
      # No .env is written for a static site: nothing it ships is secret.
      :
    elif is_sqlite; then
      # SQLite: no DB URL/CA. The Spaces keypair (Litestream replica auth) and the
      # replica target travel as secrets/vars; deploy.yml writes them into .env.
      var_set DATABASE_PATH   "$DATABASE_PATH"
      printf '%s' "$SPACES_ACCESS_KEY_ID"     | secret_set LITESTREAM_ACCESS_KEY_ID
      printf '%s' "$SPACES_SECRET_ACCESS_KEY" | secret_set LITESTREAM_SECRET_ACCESS_KEY
      var_set BACKUP_BUCKET   "$BACKUP_BUCKET"
      var_set BACKUP_ENDPOINT "$BACKUP_ENDPOINT"
      var_set BACKUP_REGION   "$BACKUP_REGION"
      var_set BACKUP_PATH     "$BACKUP_PATH"
    else
      printf '%s' "$DATABASE_URL"               | secret_set DATABASE_URL
      printf '%s' "$DATABASE_CA_CERT"           | secret_set DATABASE_CA_CERT
    fi

    # ---- PR staging environment ------------------------------------------------
    # STAGING_DOMAIN is the switch: staging.yml gates every one of its jobs on it,
    # so an app that has no staging name never runs the workflow at all. Nothing
    # else is seeded here that production doesn't already have — the staging slug
    # is derived from APP_SLUG in the workflow, and the staging stack reuses
    # DATABASE_PATH, DOCR_REGISTRY, DROPLET_HOST and FIREWALL_ID.
    if staging_enabled; then
      var_set STAGING_DOMAIN "$STAGING_DOMAIN"
      # No staging signing secret is seeded here on purpose: staging.yml derives
      # one from SECRET_KEY_BASE at deploy time (one-way, fixed label), so the
      # environment signs with a key that is not production's without anyone
      # having to create, rotate or remember a second secret.
      #
      # Postgres: the staging environment's own database in the same cluster, so
      # a PR's migrations can never run against production's.
      if [ -n "${STAGING_DATABASE_URL:-}" ]; then
        printf '%s' "$STAGING_DATABASE_URL" | secret_set STAGING_DATABASE_URL
      fi
    else
      # Staging was turned off (or never on). The variable is the workflow's only
      # switch, so leaving a stale one behind would keep deploying to a name
      # Terraform has just removed from DNS. Absent already? Then there is
      # nothing to remove and the failure is expected.
      var_delete STAGING_DOMAIN
    fi
  )
}

# Commit + push -> triggers CI = the FIRST deploy via the SAME path as later ones.
#
# A re-run of the bootstrap after fixing something that lives OUTSIDE git — a
# full container registry, a rotated secret, a changed repo variable — commits
# nothing and so pushes nothing, which fires no `push` event and starts no
# deploy. Left there, the next step would poll the PREVIOUS run and report its
# already-fixed failure as this run's verdict, and no amount of re-running could
# ever go green. So: when nothing reached the code host, dispatch the workflow.
commit_push() {
  log "commit + push (triggers first deploy via CI)"
  local before after
  before="$(git -C "$APP_DIR" rev-parse origin/main 2>/dev/null || echo none)"
  ( cd "$APP_DIR"
    git add -A
    if git diff --cached --quiet; then
      log "nothing new to commit"
    else
      git commit -q -m "chore: wire push-button deploy pipeline"
    fi
    provider_git_push -u origin main
  )
  after="$(git -C "$APP_DIR" rev-parse origin/main)"
  HEAD_SHA="$(git -C "$APP_DIR" rev-parse HEAD)"

  # The run confirm_live is allowed to judge must be one this invocation caused.
  # Remember the newest run that already existed for this commit, so a stale
  # conclusion left over from an earlier attempt cannot be mistaken for ours.
  PREV_RUN_ID="$(latest_run_id)"
  if [ "$before" != "$after" ]; then
    DEPLOY_TRIGGERED=1                       # the push itself started the deploy
    return 0
  fi
  case "$(run_state)" in
    ""|completed*)
      log "nothing pushed — dispatching $CI_WORKFLOW so this run re-runs against main"
      ci_dispatch_deploy
      DEPLOY_TRIGGERED=1 ;;
    *)
      log "a deploy for this commit is already running — waiting on it"
      DEPLOY_TRIGGERED=0 ;;
  esac
}

# ---- story 6.3: confirm liveness ----------------------------------------------

# The newest deploy run for the commit we just pushed, as "id status conclusion".
# Empty until the provider registers a run. (ci_run_row, scripts/provider.sh)
run_row() {
  ci_run_row
}

latest_run_id() { local r; r="$(run_row)"; printf '%s' "${r%% *}"; }

# The state of OUR deploy, as "status conclusion". A provider takes a few seconds
# to register a freshly pushed or dispatched run, and in that window the newest run
# for this commit is still the previous attempt — whose "completed failure"
# would otherwise end the bootstrap instantly with a verdict about a problem
# that has already been fixed. Report "not registered yet" (empty) until the id
# moves off the one we recorded before triggering.
run_state() {
  local row id
  row="$(run_row)"
  [ -n "$row" ] || return 0
  id="${row%% *}"
  if [ "${DEPLOY_TRIGGERED:-0}" = 1 ] && [ -n "${PREV_RUN_ID:-}" ] \
     && [ "$id" = "$PREV_RUN_ID" ]; then
    return 0
  fi
  printf '%s' "${row#* }"
}

# Ordered diagnostics (AC 6.3): Actions status, dig, Caddy logs. Always exits 1 —
# the verdict line above the dump says whether this is "deploy failed" or merely
# "not ready yet".
diagnose() {
  {
    printf '\nbootstrap: NOT LIVE — %s\n' "$1"
    printf '\n--- 1. CI Actions (deploy workflow) ---\n'
    ci_diagnose_dump
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
    printf '\nnext: %s; after a fix, re-run ./bootstrap.sh (idempotent)\n' "$(ci_watch_hint)"
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
        diagnose "deploy FAILED — CI run concluded '${state#completed }'. See run log: $(ci_log_hint)" ;;
    esac
    [ "$waited" -lt "$timeout" ] \
      || case "$state" in
           "completed success")
             diagnose "deploy succeeded but HTTPS not answering after ${timeout}s — likely DNS propagation or Let's Encrypt issuance; see dig/Caddy below" ;;
           *)
             diagnose "not ready yet (CI still running after ${timeout}s — NOT a failure). Keep watching: $(ci_watch_hint)" ;;
         esac
    # heartbeat every 60s so a long CI build never reads as a hang
    if [ $((waited % 60)) -eq 0 ] && [ "$waited" -gt 0 ]; then
      log "  still waiting (${waited}s) — CI state: ${state:-no run registered yet}"
    fi
    sleep 10; waited=$((waited + 10))
  done
}

# The droplet-free counterpart of diagnose(): there is no DNS to dig, no Caddy
# to read and no stack on any host, so the CI run is the whole story.
diagnose_ci() {
  {
    printf '\nbootstrap: CI NOT GREEN — %s\n' "$1"
    printf '\n--- CI runs (%s) ---\n' "$CI_WORKFLOW"
    ci_diagnose_dump
    printf '\nnext: %s; after a fix, re-run ./bootstrap.sh (idempotent)\n' "$(ci_watch_hint)"
  } >&2
  exit 1
}

# What confirm_live is for a service, this is for everything droplet-free: the
# pipeline concluding green IS the deliverable, because nothing is served and
# there is no URL to poll. Same run bookkeeping (PREV_RUN_ID / DEPLOY_TRIGGERED
# via run_state), so a stale conclusion from an earlier attempt is never read as
# this invocation's verdict.
confirm_ci() {
  local timeout="${LIVE_TIMEOUT_SECS:-900}" waited=0 state
  log "waiting for $CI_WORKFLOW to conclude (timeout ${timeout}s)..."
  while :; do
    state="$(run_state)"
    case "$state" in
      "completed success")
        log "CI GREEN: $CI_WORKFLOW passed"
        return 0 ;;
      "completed failure"|"completed cancelled"|"completed timed_out")
        diagnose_ci "the run concluded '${state#completed }'. See the log: $(ci_log_hint)" ;;
      "completed skipped")
        diagnose_ci "the run was SKIPPED — no job matched this event. Check $CI_WORKFLOW's triggers." ;;
    esac
    [ "$waited" -lt "$timeout" ] \
      || diagnose_ci "still running after ${timeout}s — NOT a failure. Keep watching: $(ci_watch_hint)"
    # heartbeat every 60s so a long build never reads as a hang
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
  step "code host repo + initial commit";           ensure_repo

  # A droplet-free app stops here for everything infrastructural: there is no
  # state bucket, no Terraform root, no registry, no droplet and no DNS record
  # to create, and so nothing to wait for, grant on, or tear down later. What is
  # left is exactly the part that is the same for every app — a repo with a
  # pipeline in it — and CI going green is the whole verdict.
  if ! needs_droplet; then
    step "prepare app: CI pipeline files";          prep_app
    step "seed CI secrets + variables";             seed_ci
    step "commit + push (triggers CI)";             commit_push
    step "poll until CI concludes";                 confirm_ci
    log "done. $APP_TYPE '$APP_NAME' built and green — no infrastructure was provisioned, so there is nothing to bill and nothing to tear down."
    return 0
  fi

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
  step "seed CI secrets + variables";               seed_ci
  step "commit + push pipeline (first deploy)";     commit_push
  step "poll until live";                           confirm_live
  if is_tenant; then
    log "done. app live at https://$DOMAIN | droplet: $APP_IP (shared with $(basename "$HOST_APP_DIR"))"
  else
    log "done. app live at https://$DOMAIN | droplet: $APP_IP"
  fi
  # if/fi, not `&&`: as the last command in the function a false test would make
  # provision() return non-zero, and set -e would stamp a successful run FAILED.
  if staging_enabled; then
    log "staging: a PR against main deploys to https://$STAGING_DOMAIN, and closing it destroys that environment"
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

# ---- interactive mode --------------------------------------------------------
#
# --interactive / -i walks the same choices the flags and environment encode —
# app type, language, code host, and (for a service) database backend, PR
# staging and tenancy — then SETS the very variables the flag parser would have
# set and hands off to the same resolve_app_config -> provision() path a
# non-interactive run takes. There is no second code path for "what a choice
# means": resolve_app_config validates and coerces exactly as before, so the
# menus can never drift from the flags they stand in for. The menus themselves
# are rendered from the app-type registry (scripts/app-types.sh), so a stack
# added there shows up here with no edit.
#
# Each prompt writes to stderr and sets $REPLY_VALUE — it does NOT echo the
# answer for a `$(...)` to capture. That is deliberate: a command substitution
# runs in a subshell, and a fail() (e.g. the terminal closing mid-session) from
# inside one would only kill the subshell, leaving the parent to march on with
# an empty value. Setting a global keeps every fail() in the main shell, where
# it actually stops the run. Answers are read from /dev/tty, so a redirected or
# piped stdin never swallows a prompt — and ask_menu can take its option list on
# its own stdin (via process substitution) without the two contending.
REPLY_VALUE=""

ask_line() { # $1 prompt -> sets REPLY_VALUE to the entered line (empty on Enter)
  printf '%s' "$1" >&2
  IFS= read -r REPLY_VALUE < /dev/tty \
    || fail "interactive: input closed — --interactive needs a terminal (drop it and use the flags; see --help)"
}

ask_text() { # $1 label, $2 default -> REPLY_VALUE (the default on empty input)
  local d="$2"
  ask_line "$1${d:+ [$d]}: "
  [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$d"
}

ask_yesno() { # $1 label, $2 default (y/n) -> REPLY_VALUE 'true' or 'false'
  local d="$2"
  while :; do
    ask_line "$1 (y/n) [$d]: "; [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$d"
    case "$REPLY_VALUE" in
      y|Y|yes|true)  REPLY_VALUE=true;  return ;;
      n|N|no|false)  REPLY_VALUE=false; return ;;
      *) printf '  please answer y or n\n' >&2 ;;
    esac
  done
}

# Numbered menu. Options arrive on stdin as `value|description` lines; the
# chosen VALUE lands in REPLY_VALUE. A bare Enter takes the default (marked *);
# a name is accepted as readily as its number.
ask_menu() { # $1 label, $2 default-value  (options on stdin)
  local label="$1" default="$2" val desc n=0 i
  local -a vals=() descs=()
  while IFS='|' read -r val desc; do
    [ -n "$val" ] || continue
    n=$((n + 1)); vals+=("$val"); descs+=("$desc")
  done
  printf '\n%s\n' "$label" >&2
  for ((i = 1; i <= n; i++)); do
    local mark=" "; [ "${vals[i-1]}" = "$default" ] && mark="*"
    printf '  %s%s) %-10s %s\n' "$mark" "$i" "${vals[i-1]}" "${descs[i-1]}" >&2
  done
  while :; do
    ask_line "choice [$default]: "; [ -n "$REPLY_VALUE" ] || REPLY_VALUE="$default"
    for ((i = 1; i <= n; i++)); do
      [ "$REPLY_VALUE" = "${vals[i-1]}" ] && return
    done
    case "$REPLY_VALUE" in
      ''|*[!0-9]*) ;;
      *) if [ "$REPLY_VALUE" -ge 1 ] && [ "$REPLY_VALUE" -le "$n" ]; then
           REPLY_VALUE="${vals[REPLY_VALUE-1]}"; return
         fi ;;
    esac
    printf '  pick 1-%s, or a name\n' "$n" >&2
  done
}

# Walk the choices, set the parser's variables, leave the target dir in
# INTERACTIVE_APP_DIR. Called with main's remaining positionals so the directory
# prompt can default to one already typed. Everything it decides is re-validated
# by resolve_app_config; nothing here provisions.
interactive() {
  [ -r /dev/tty ] || fail "--interactive needs a terminal (no /dev/tty). Use the flags instead (see --help)."
  log "interactive setup — Enter accepts the [default] shown at each step"

  # 1. App type — the shape, and therefore what infrastructure it needs.
  local type_default="${APP_TYPE_FLAG:-${APP_TYPE:-$APP_TYPE_DEFAULT}}"
  local type
  ask_menu "What are you building?" "$type_default" \
    < <(printf '%s\n' "$APP_TYPE_TABLE" | awk -F'|' '{print $1"|"$6}')
  type="$REPLY_VALUE"; APP_TYPE_FLAG="$type"

  # 2. Language / framework within it (the stacks of that type, from the table).
  local lang_default="${LANGUAGE_FLAG:-${LANGUAGE:-}}"
  [ -n "$lang_default" ] || lang_default="$(type_stacks "$type" | head -1 | cut -d'|' -f3)"
  local lang
  ask_menu "Which language?" "$lang_default" \
    < <(type_stacks "$type" | awk -F'|' '{print $3"|"$8}')
  lang="$REPLY_VALUE"; LANGUAGE_FLAG="$lang"

  # The framework the pair resolves to — the follow-ups key on it, not on names.
  local fw; fw="$(resolve_framework "$type" "$lang")"

  # 3. Code host + CI engine (every type has one).
  ask_menu "Where do the repo and CI live?" "${GIT_PROVIDER:-github}" \
    < <(printf 'github|GitHub (github.com), GitHub Actions\ngitea|self-hosted Gitea + its Actions runner\n')
  GIT_PROVIDER="$REPLY_VALUE"; export GIT_PROVIDER

  # 4. Service-only infrastructure choices, gated on the SAME predicates
  #    resolve_app_config uses — asked only when they can actually apply.
  if [ "$(type_droplet "$type")" = yes ]; then
    # Database: only where the type may have one AND the framework does not force
    # it (sinatra is SQLite-only, zola has none). Matches resolve_app_config's
    # coercions, so nothing offered here gets silently overridden later.
    if [ "$(type_database "$type")" = yes ] && [ "$fw" != sinatra ] && [ "$fw" != zola ]; then
      ask_menu "Database backend?" "${DATABASE_BACKEND:-sqlite}" \
        < <(printf 'sqlite|a file on the droplet, streamed to Spaces by Litestream (~$0)\npostgres|DigitalOcean Managed Postgres, private-VPC (~$15/mo)\n')
      DATABASE_BACKEND="$REPLY_VALUE"; export DATABASE_BACKEND
    fi
    # PR staging: GitHub only (no Gitea workflow yet) and never for a static site.
    if [ "$GIT_PROVIDER" = github ] && [ "$fw" != zola ]; then
      local stg_default=y; [ "${ENABLE_STAGING:-true}" = false ] && stg_default=n
      ask_yesno "Give every PR a staging environment at <app>-stg.<zone>?" "$stg_default"
      ENABLE_STAGING="$REPLY_VALUE"; export ENABLE_STAGING
    fi
    # Tenancy: deploy onto a droplet another app already owns. Blank = its own.
    ask_text "Share an EXISTING droplet? Enter that host app's directory (blank = its own droplet)" "${HOST_APP_DIR:-}"
    [ -z "$REPLY_VALUE" ] || HOST_APP_DIR="$(abs_dir "$REPLY_VALUE")"
  fi

  # 5. Where it lands. Default to a directory already on the command line, else '.'.
  ask_text "App directory" "${1:-.}"; INTERACTIVE_APP_DIR="$REPLY_VALUE"

  # 6. Recap and confirm before anything happens.
  printf '\n' >&2
  log "about to build:"
  printf '    type        %s\n' "$type" >&2
  printf '    language    %s  (framework: %s)\n' "$lang" "$fw" >&2
  printf '    directory   %s\n' "$(abs_dir "$INTERACTIVE_APP_DIR")" >&2
  printf '    code host   %s\n' "$GIT_PROVIDER" >&2
  if [ "$(type_droplet "$type")" = yes ]; then
    if [ "$(type_database "$type")" = yes ] && [ "$fw" != sinatra ] && [ "$fw" != zola ]; then
      printf '    database    %s\n' "${DATABASE_BACKEND:-sqlite}" >&2
    fi
    [ "$GIT_PROVIDER" = github ] && [ "$fw" != zola ] \
      && printf '    staging     %s\n' "${ENABLE_STAGING:-true}" >&2
    [ -n "${HOST_APP_DIR:-}" ] && printf '    host app    %s  (tenant)\n' "$HOST_APP_DIR" >&2
  fi
  printf '\n' >&2
  [ "$(ask_yesno "Proceed?" y)" = true ] || fail "cancelled"
}

usage() {
  cat <<EOF
bootstrap.sh — stand up an app, its repo and its pipeline.

  ./bootstrap.sh [options] [app_dir]     app_dir defaults to .

  ./bootstrap.sh ~/src/myapp             a Phoenix app on a droplet, over HTTPS
  ./bootstrap.sh --cli ruby ~/src/mytool a Ruby command-line program
  ./bootstrap.sh --no-droplet ~/src/mylib   a reusable package

Options:
  --interactive, -i    prompt step by step for every choice below, then deploy.
                       Skips no validation — it just fills the flags for you
  --check              verify prerequisites and exit; provisions nothing
  --host <dir>         TENANT MODE: deploy onto the droplet <dir>'s app already
                       owns instead of provisioning one (service apps only)
  --lang <language>    which language to build in, within the app type. Also
                       spelled as an argument to the type flag: --cli ruby,
                       --cli=ruby and --lang ruby are the same thing
  --no-droplet         build something that provisions no droplet. On its own
                       that means a $NO_DROPLET_DEFAULT_TYPE; with a type flag it asserts the
                       type is droplet-free and fails if it is not
  --help               this message

App types (or APP_TYPE in the environment / .env):
$(app_type_help)
Languages, per type (or LANGUAGE / FRAMEWORK):
$(app_stack_help)
Every CLI ships real argument parsing — \`mytool --format json hello\`, --help,
--version, positional arguments and exit codes — over its language's standard
option parser. None of them is a script you configure with environment
variables.

The droplet-free types need no DigitalOcean, DNSimple, Spaces or SSH
credentials: preflight asks for the code host and nothing else.

Adding a language or a type — gems, hex packages, OTP apps — is a row in
scripts/app-types.sh plus a scaffold script and a CI workflow template.
EOF
}

main() {
  local check=0 interactive=0 t arg val
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      --interactive|-i) interactive=1; shift ;;
      --help|-h) usage; exit 0 ;;
      # The language axis, spelled on its own. `--cli ruby` and `--cli=ruby`
      # below reach the same variable.
      --lang|--language)
        [ -n "${2:-}" ] || fail "--lang needs a language (see --help)"
        LANGUAGE_FLAG="$2"; shift 2 ;;
      --lang=*|--language=*) LANGUAGE_FLAG="${1#*=}"; shift ;;
      # Tenant mode: deploy onto the droplet this app already owns. Equivalent
      # to HOST_APP_DIR in the environment; the flag wins.
      --host)
        [ -n "${2:-}" ] || fail "--host needs the host app's directory"
        HOST_APP_DIR="$(abs_dir "$2")"; shift 2 ;;
      --host=*) HOST_APP_DIR="$(abs_dir "${1#--host=}")"; shift ;;
      # A CONSTRAINT, not a type: see resolve_app_type in scripts/app-types.sh.
      --no-droplet) REQUIRE_NO_DROPLET=1; shift ;;
      # One --<type> flag per row of the app-type table, matched against the
      # table itself so a type added later needs no case arm here. Each accepts
      # its language two ways: `--cli=ruby` and `--cli ruby`.
      --*)
        arg="${1%%=*}"; val=""
        case "$1" in *=*) val="${1#*=}" ;; esac
        t="$(printf '%s\n' "$APP_TYPE_TABLE" | awk -F'|' -v f="$arg" '$2 == f { print $1; exit }')"
        [ -n "$t" ] || fail "unknown argument: $1
$(usage)"
        [ -z "$APP_TYPE_FLAG" ] || [ "$APP_TYPE_FLAG" = "$t" ] \
          || fail "conflicting app types: --$APP_TYPE_FLAG and $arg — pick one"
        APP_TYPE_FLAG="$t"; shift
        if [ -n "$val" ]; then
          LANGUAGE_FLAG="$val"
        else
          # A BARE next argument that names one of this type's languages is the
          # language, not the app directory — so `--cli ruby ~/src/tool` reads
          # the way it looks. Only a bare token: anything with a slash (./ruby,
          # ~/src/ruby) is unambiguously a path and is left alone. A directory
          # named exactly `ruby` in the current directory therefore needs
          # `./ruby`, which --help says.
          case "${1:-}" in
            */*|"") ;;
            *)
              if is_language_of "$t" "$1"; then
                LANGUAGE_FLAG="$1"; shift
              elif [ -n "$(language_owners "$1")" ]; then
                # A real language, but not one THIS type builds in. Left alone it
                # would silently become the app directory's name, and the run
                # would build the type's default stack in ./typescript.
                fail "'$1' is not a $t language — $t builds in: $(type_languages "$t")
       ($1 is a $(language_owners "$1") language: $(language_type_examples "$1"))
       If you did mean a directory called '$1', write it as ./$1."
              fi ;;
          esac
        fi ;;
      -*) fail "unknown argument: $1
$(usage)" ;;
      *)  break ;;
    esac
  done

  # Interactive mode fills in the same flag/env variables the parser above would
  # have set (app type, language, code host, database, staging, tenancy, target
  # dir), then falls through to the identical path below — resolve_app_config
  # still validates and coerces, so an interactive run and a flag run that pick
  # the same answers are indistinguishable from here on.
  if [ "$interactive" -eq 1 ]; then
    interactive "$@"
    set -- "$INTERACTIVE_APP_DIR"
  fi

  # Resolve WHAT is being built before anything asks what it needs: the type
  # decides the required binaries, the required credentials and the step count.
  resolve_app_config

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
