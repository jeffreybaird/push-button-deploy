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

# Interactive prompt primitives (ask_line/ask_text/ask_yesno/ask_menu +
# REPLY_VALUE), shared with claude-docs.sh. Ordering is unconstrained — these
# are called only at runtime, in --interactive mode — but keeping the source
# here alongside the other libs is the clearest place. Requires fail() (defined
# above).
# shellcheck source=scripts/prompt.sh
. "$SCRIPT_DIR/scripts/prompt.sh"

# The shared Claude-docs injector — the automatic doc injection during app
# generation goes through it, and --interactive can drive its guided selection.
# It reuses this script's fail()/log() and the prompt helpers above.
# shellcheck source=scripts/claude-docs.sh
. "$SCRIPT_DIR/scripts/claude-docs.sh"

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

# Bootstrap owns the execution order; implementation lives by responsibility.
# shellcheck source=scripts/bootstrap/app.sh
. "$SCRIPT_DIR/scripts/bootstrap/app.sh"
# shellcheck source=scripts/bootstrap/infrastructure.sh
. "$SCRIPT_DIR/scripts/bootstrap/infrastructure.sh"
# shellcheck source=scripts/bootstrap/repository.sh
. "$SCRIPT_DIR/scripts/bootstrap/repository.sh"

# shellcheck source=scripts/deployment.sh
. "$SCRIPT_DIR/scripts/deployment.sh"

provision() {
  local identity
  # A tenant skips the five host-only steps and runs three of its own.
  is_tenant && TOTAL_STEPS=14
  log "transcript of this run: $LOG_FILE"
  step "preflight checks";                          preflight
  step "ensure app exists (generate if missing)";   ensure_app
  step "read app identity and derive infrastructure names"
  identity="$(read_app_identity "$APP_DIR" "$APP_TYPE" "$FRAMEWORK" "$LANGUAGE")"
  IFS='|' read -r APP_NAME APP_MODULE <<< "$identity"
  derive_infrastructure_names "$APP_NAME"
  log_app_identity
  step "code host repo + initial commit";           ensure_repo

  # A droplet-free app stops here for everything infrastructural: there is no
  # state bucket, no Terraform root, no registry, no droplet and no DNS record
  # to create, and so nothing to wait for, grant on, or tear down later. What is
  # left is exactly the part that is the same for every app — a repo with a
  # pipeline in it — and CI going green is the whole verdict.
  if ! needs_droplet; then
    step "prepare app: CI pipeline files";          prepare_app "$APP_DIR" "$APP_TYPE" "$FRAMEWORK" "$DATABASE_BACKEND" "$GIT_PROVIDER"
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
  step "prepare app: release/TLS/pipeline files";   prepare_app "$APP_DIR" "$APP_TYPE" "$FRAMEWORK" "$DATABASE_BACKEND" "$GIT_PROVIDER"
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
# The prompt primitives (ask_line/ask_text/ask_yesno/ask_menu + REPLY_VALUE)
# live in scripts/prompt.sh, sourced near the top of this script — they are
# shared with claude-docs.sh. Their contract: each writes to stderr and sets
# $REPLY_VALUE (not stdout), reads answers from /dev/tty, and calls fail() on a
# closed terminal. See that file for the full rationale.

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

  # 5b. Claude docs — optionally tailor which .claude modules/agents/hooks the
  #     generated app gets. Only for a framework that ships a doc template
  #     (phoenix/sinatra/zola); CLIs and libraries have none. The CD_SKIP_*
  #     selections are exported so the scaffold/inject child processes honor
  #     them; left unset (the default), every module + agent + hook is included.
  local _docs_tmpl; _docs_tmpl="$(cd_template_dir "$fw")"
  if [ -n "$_docs_tmpl" ]; then
    ask_yesno "Customize which Claude docs (modules, agents, hooks) the app gets?" n
    if [ "$REPLY_VALUE" = true ]; then
      cd_prompt_selection "$_docs_tmpl"
      export CD_SKIP_MODULES CD_SKIP_AGENTS CD_HOOK CD_NO_SETUP
      INTERACTIVE_DOCS_CUSTOMIZED=1
    fi
  fi

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
  [ -n "${INTERACTIVE_DOCS_CUSTOMIZED:-}" ] \
    && printf '    claude docs customized (see the prompts above)\n' >&2
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
  --docs               guided creation of the app's Claude docs (CLAUDE.md +
                       .claude/) only — provisions nothing. Delegates to
                       ./claude-docs.sh; run that directly for its own options
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
  local check=0 interactive=0 docs_only=0 t arg val
  while [ $# -gt 0 ]; do
    case "$1" in
      --check) check=1; shift ;;
      --interactive|-i) interactive=1; shift ;;
      # Guided Claude-docs only — write CLAUDE.md + .claude/ and stop, provision
      # nothing. Handled after the loop by delegating to ./claude-docs.sh, which
      # shares scripts/claude-docs.sh with this script.
      --docs) docs_only=1; shift ;;
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

  # --docs: guided Claude-docs, no provisioning. Delegate to the standalone
  # command (which shares scripts/claude-docs.sh). FRAMEWORK, if set in the
  # environment, is inherited; otherwise claude-docs.sh infers it from the app's
  # marker file or prompts. Forward the target dir if one was given.
  if [ "$docs_only" -eq 1 ]; then
    exec "$SCRIPT_DIR/claude-docs.sh" ${1:+"$1"}
  fi

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
