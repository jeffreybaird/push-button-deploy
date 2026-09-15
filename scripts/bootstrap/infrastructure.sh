# Infrastructure lifecycle operations in provisioning order.
# Inputs: resolved app/host config, Terraform root paths, and cloud credentials.
# Outputs: applied resource identity (APP_IP, DOMAIN, FW_ID), database and backup
# connection values, and STAGING_* values consumed by repository CI configuration.
# Requires log(), warn(), fail(), quiet(), capability predicates and SCRIPT_DIR.

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
