# Repository creation and CI configuration.
# Inputs: APP_DIR/APP_NAME, resolved provider, and applied infrastructure outputs.
# Requires provider.sh and capability predicates. Remote writes happen only when
# ensure_repo() or seed_ci() is called; sourcing this module performs no actions.

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
