# Resolved application policy. Source after the registry and provider libraries.
# Functions define defaults/validation without cloud calls or filesystem writes.
# Outputs: DATABASE_BACKEND, ENABLE_STAGING, REQUIRED_BINS and REQUIRED_ENV.

is_sqlite() { [ "$DATABASE_BACKEND" = sqlite ]; }
is_sinatra() { [ "$FRAMEWORK" = sinatra ]; }
is_phoenix() { [ "$FRAMEWORK" = phoenix ]; }
is_zola() { [ "$FRAMEWORK" = zola ]; }
is_static() { is_zola; }
is_tenant() { [ -n "${HOST_APP_DIR:-}" ]; }
wants_staging() { [ "${ENABLE_STAGING:-true}" = true ] && needs_droplet && ! is_static && is_github; }
staging_enabled() { [ -n "${STAGING_DOMAIN:-}" ]; }

resolve_database_backend() {
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

}

resolve_staging_policy() {
  # PR staging environments, on by default for anything with a server-side
  # runtime. Turning it off here removes the staging DNS record (and, on
  # Postgres, the staging database) on the next apply; the workflow shipped with
  # the app then finds no STAGING_DOMAIN variable and skips every job.
  ENABLE_STAGING="${ENABLE_STAGING:-true}"
  # Staging has no Gitea workflow yet (see wants_staging). Silently dropping an
  # explicit request for it would be the one case where the user is owed a word
  # — but only where staging was ever on the table: a droplet-free app has no
  # environment to stand up in the first place.
  if [ "$ENABLE_STAGING" = true ] && needs_droplet && ! is_static && is_gitea; then
    warn "GIT_PROVIDER=gitea has no staging workflow yet — no PR environment will be built, and no staging DNS name or database will be provisioned"
  fi

}

validate_app_config() {
  case "$ENABLE_STAGING" in
    true|false) ;;
    *) fail "ENABLE_STAGING must be 'true' or 'false' (got '$ENABLE_STAGING')" ;;
  esac

  case "$DATABASE_BACKEND" in
    postgres|sqlite)
      has_database \
        || fail "DATABASE_BACKEND=$DATABASE_BACKEND is meaningless for a '$APP_TYPE' — it has no data layer and no host to keep one on" ;;
    # 'none' is never selectable by hand: it is what FRAMEWORK=zola and every
    # droplet-free type imply, and the coercion in resolve_database_backend is the only
    # thing that sets it.
    none) is_zola || ! has_database \
        || fail "DATABASE_BACKEND=none is only valid for FRAMEWORK=zola" ;;
    *) fail "DATABASE_BACKEND must be 'postgres' or 'sqlite' (got '$DATABASE_BACKEND')" ;;
  esac

  case "$GIT_PROVIDER" in
    github|gitea) ;;
    *) fail "GIT_PROVIDER must be github or gitea" ;;
  esac
}

required_binaries() { # $1 type, $2 framework, $3 provider
  local APP_TYPE="$1" FRAMEWORK="$2" GIT_PROVIDER="$3"
  # Local tooling, by capability rather than by name. A droplet-free app talks to
  # the code host and nothing else, so it needs neither the DigitalOcean CLI nor
  # Terraform nor an SSH client — and its scaffolds are pure bash, so it does not
  # even need a local Elixir.
  local bins="git curl"
  if needs_droplet; then bins="$bins terraform doctl ssh scp dig"; fi
  # Framework-specific local tooling: Phoenix generates + prepares the app with
  # `mix`; Sinatra scaffolds with bash and only needs `openssl` (fresh session
  # secret) — the Ruby build itself happens in Docker/CI, not locally. Zola and
  # the droplet-free frameworks add nothing: their scaffolds are written by hand
  # and their builds run in CI.
  if is_sinatra; then bins="$bins openssl"
  elif is_phoenix; then bins="$bins mix"; fi
  # gh drives the GitHub path end to end; the Gitea path talks REST over curl
  # (already required) and leans on jq for safe JSON bodies + run-status parsing.
  if is_github; then bins="$bins gh"
  elif is_gitea; then bins="$bins jq"; fi

  printf '%s\n' "$bins"
}

required_credentials() { # $1 type, $2 provider
  local APP_TYPE="$1" GIT_PROVIDER="$2"
  # Same rule for credentials: what is never contacted is never demanded. This
  # is what lets `./bootstrap.sh --cli ~/src/tool` run on a machine that has
  # never heard of DigitalOcean.
  local credentials=""
  if needs_droplet; then
    credentials="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SSH_KEY_NAME SSH_PRIVATE_KEY SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"
  fi
  # GITEA_OWNER is deliberately NOT required: unset, the repo is created under
  # whichever account GITEA_TOKEN authenticates as (see ci_auth_check) — the same
  # implicit-current-user behavior gh already gives the GitHub path.
  if is_gitea; then
    credentials="$credentials GITEA_URL GITEA_TOKEN"
    # The runner IP exists to be allow-listed in the droplet firewall. No
    # droplet, no firewall, nothing to allow-list.
    needs_droplet && credentials="$credentials GITEA_RUNNER_IP"
  fi

  printf '%s\n' "$credentials"
}

derive_requirements() {
  REQUIRED_BINS="$(required_binaries "$APP_TYPE" "$FRAMEWORK" "$GIT_PROVIDER")"
  REQUIRED_ENV="$(required_credentials "$APP_TYPE" "$GIT_PROVIDER")"
}

resolve_app_config() {
  resolve_app_type
  resolve_database_backend
  resolve_staging_policy
  validate_app_config
  derive_requirements
}
