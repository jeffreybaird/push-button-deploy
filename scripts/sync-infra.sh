#!/usr/bin/env bash
#
# sync-infra.sh — seed an app repo with its OWN copy of the Terraform roots.
#
#   ./scripts/sync-infra.sh [--tenant] <app_dir>
#
# After this runs, <app_dir>/infra/{state,persistent,app}/ holds the Terraform
# that owns that app's infrastructure, and bootstrap.sh/teardown.sh operate on
# those copies rather than the ones in this repo. The app's infra therefore
# travels with the app: clone the repo, and you can change the deploy.
#
# --tenant seeds ONE root instead — infra/tenant/ — for an app that deploys onto
# a droplet another app already owns. A tenant provisions no droplet, no IP, no
# bucket and no database: it adds a DNS record pointing at the host's reserved
# IP and shares everything else. Copying the host's roots into a tenant would be
# worse than useless, since `terraform destroy` there would take down the host.
#
# SEED ONCE, NEVER CLOBBER: a file that already exists in the app is left alone,
# so hand edits survive re-runs of bootstrap.sh. Files that drift from this
# repo's version are reported (not overwritten) so an intentional local change
# is visible and an accidental one is findable.
#
# Portable: BSD/macOS bash, cmp.
set -euo pipefail

fail() { printf 'sync-infra: %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[32m==>\033[0m %s\n' "$*"; }

TENANT=0
if [ "${1:-}" = "--tenant" ]; then TENANT=1; shift; fi

APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail "usage: sync-infra.sh [--tenant] <app_dir>"
[ -d "$APP_DIR" ] || fail "no such directory: $APP_DIR"
APP_DIR="$(cd "$APP_DIR" && pwd)"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Only SOURCE files travel. State, backend pointers, provider caches and real
# tfvars are per-machine or per-run artifacts — copying them would either leak
# credentials into the app repo or hand it a stale state file.
copy_root() { # $1: root name (state|persistent|app)
  local src="$REPO_DIR/infra-$1" dst="$APP_DIR/infra/$1"
  [ -d "$src" ] || fail "missing source root: $src"
  mkdir -p "$dst"

  local f base
  for f in "$src"/*.tf "$src"/cloud-init.yaml "$src"/terraform.tfvars.example; do
    [ -f "$f" ] || continue
    base="$(basename "$f")"
    if [ ! -e "$dst/$base" ]; then
      cp "$f" "$dst/$base"
      NEW="$NEW infra/$1/$base"
    elif ! cmp -s "$f" "$dst/$base"; then
      DRIFT="$DRIFT infra/$1/$base"
    fi
  done
}

NEW=""
DRIFT=""
if [ "$TENANT" -eq 1 ]; then
  copy_root tenant
else
  copy_root state
  copy_root persistent
  copy_root app
fi

# The app repo must never commit state, provider caches, generated backend
# pointers or real tfvars — same rules as this repo, scoped to infra/.
if [ ! -e "$APP_DIR/infra/.gitignore" ]; then
  cat > "$APP_DIR/infra/.gitignore" <<'EOF'
# Terraform working files — never commit these.
.terraform/
*.tfstate
*.tfstate.*
crash.log

# Real variable files may hold tokens; the .example files are safe to commit.
*.tfvars
!*.tfvars.example

# Written by bootstrap.sh/teardown.sh from the project's env (bucket + endpoint).
backend.hcl

# Written by teardown.sh while it lifts a prevent_destroy guard.
teardown_override.tf
EOF
  NEW="$NEW infra/.gitignore"
fi

if [ ! -e "$APP_DIR/infra/README.md" ] && [ "$TENANT" -eq 1 ]; then
  cat > "$APP_DIR/infra/README.md" <<'EOF'
# infra/ — this app's infrastructure (TENANT)

This app is a **tenant**: it runs on a droplet another app already owns, behind
that droplet's shared Caddy. It therefore owns exactly one piece of
infrastructure of its own.

```
infra/tenant/       the DNSimple A record for this app's domain, pointed at the
                    HOST droplet's reserved IP (read from the host's Terraform
                    state in the shared Spaces bucket).
```

Everything else — droplet, reserved IP, firewall, VPC, state bucket, container
registry — belongs to the host app and is shared. Destroying this root removes
this app's DNS record and nothing else; the host and its other tenants are
untouched by design.

On the droplet this app lives in `/root/apps/<slug>/` as its own compose
project, with its own volumes, and contributes one site file to the shared Caddy
at `/root/caddy/sites/<slug>.caddy`.

## Changing the deploy

```bash
/path/to/push-button-deploy/bootstrap.sh --host <host_app_dir> /path/to/this/app
```

Idempotent. The bootstrap seeds these files once and never overwrites them, so
local edits survive; drift from the upstream template is reported.

## Applying by hand

Terraform here reads every input from `TF_VAR_*` and authenticates the Spaces
backend with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` (the Spaces keypair):

```bash
terraform -chdir=infra/tenant init -input=false -backend-config=backend.hcl
terraform -chdir=infra/tenant plan
```

Do NOT add a `terraform.tfvars`: tfvars outrank `TF_VAR_*` env, so it would
silently override what the bootstrap passes in. The bootstrap fails loudly if it
finds one.

## Tearing down

```bash
/path/to/push-button-deploy/teardown.sh /path/to/this/app
```

For a tenant that removes the DNS record, this app's stack and volumes on the
droplet, and its route from the shared Caddy. It never touches the droplet.
EOF
  NEW="$NEW infra/README.md"
elif [ ! -e "$APP_DIR/infra/README.md" ]; then
  cat > "$APP_DIR/infra/README.md" <<'EOF'
# infra/ — this app's infrastructure

Three Terraform roots own everything this app runs on. They live here, in the
app repo, so a change to the deploy is a change to this repo — reviewed,
committed and rolled back like any other code.

```
infra/state/        the DO Spaces bucket that stores the other two roots' state.
                    Its own state is LOCAL (chicken/egg) and per-project via a
                    Terraform workspace. Losing it is a non-event:
                    `terraform import` re-adopts the bucket.

infra/persistent/   VPC, reserved IP, managed Postgres (Postgres backend only),
                    DNSimple A record — things that must SURVIVE.
                    prevent_destroy is set on the DB cluster and reserved IP.

infra/app/          droplet, reserved-IP assignment, firewall — disposable.
                    Destroying this root never touches data: the DB firewall
                    trusts a *tag* the droplet wears, not the droplet itself.
```

## Changing the deploy

The supported path is to edit the files here, commit, and re-run the bootstrap
against this directory — it is idempotent and applies all three roots in order:

```bash
/path/to/push-button-deploy/bootstrap.sh /path/to/this/app
```

The bootstrap seeds these files once and never overwrites them afterwards, so
your edits survive. It reports any file that has drifted from the upstream
template, which is how you notice an upstream fix worth adopting.

## Applying a single root by hand

Terraform here reads every input from `TF_VAR_*` environment variables and
authenticates the Spaces backend with `AWS_ACCESS_KEY_ID` /
`AWS_SECRET_ACCESS_KEY` (the Spaces keypair). The bootstrap exports all of them;
by hand you must export them yourself, then:

```bash
terraform -chdir=infra/app init -input=false -backend-config=backend.hcl
terraform -chdir=infra/app plan
```

`backend.hcl` (bucket + endpoint) is generated by the bootstrap and gitignored —
run the bootstrap once on this machine before applying a root by hand.

Do NOT add a `terraform.tfvars` file: Terraform's precedence puts tfvars above
`TF_VAR_*` env, so it would silently override what the bootstrap passes in. The
bootstrap fails loudly if it finds one.

## Tearing down

```bash
/path/to/push-button-deploy/teardown.sh /path/to/this/app
```

Destroys the droplet, then the persistent root (**the database and all its
data**), then the state bucket. Add `--delete-repo` to remove the GitHub repo.
EOF
  NEW="$NEW infra/README.md"
fi

if [ -n "$NEW" ]; then
  log "infra: seeded into $APP_DIR:"
  for f in $NEW; do printf '      + %s\n' "$f"; done
else
  log "infra: already present in $APP_DIR"
fi

if [ -n "$DRIFT" ]; then
  printf '\033[33m==> WARN\033[0m infra: these differ from %s (kept the app'\''s version):\n' "$REPO_DIR" >&2
  for f in $DRIFT; do printf '      ~ %s\n' "$f" >&2; done
  printf '    diff against upstream: diff -ru %s/infra-<root> %s/infra/<root>\n' "$REPO_DIR" "$APP_DIR" >&2
fi
