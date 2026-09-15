#!/usr/bin/env bash
#
# teardown.sh — destroy everything bootstrap.sh created, in reverse order:
#
#   1. infra/app        droplet, firewall, reserved-IP assignment
#   2. infra/persistent DB CLUSTER (ALL DATA), VPC, reserved IP, tag, DNS record
#   3. registry         the app's image repository (the registry itself stays)
#   4. infra/state      the Terraform state bucket (deleted LAST — it holds the
#                       state of roots 1 and 2 while they are being destroyed)
#
#   ./teardown.sh [--plan] [--yes] [--delete-repo] [app_dir]
#
#   --plan         display resource scope without remote calls or changes
#   --yes          skip the type-the-project-name confirmation
#   --delete-repo  also delete the code-host repo (GitHub needs
#                  `gh auth refresh -s delete_repo`; Gitea needs GITEA_TOKEN
#                  to carry delete rights — see GIT_PROVIDER in bootstrap.sh)
#   app_dir        the app directory (default: .) — holds the app's own Terraform
#                  roots under infra/, and names the registry/code-host repo
#
# The roots destroyed are the APP'S copies (<app_dir>/infra/), the same ones
# bootstrap.sh applied. Apps bootstrapped before infra/ existed fall back to
# this repo's infra-* directories.
#
# DROPLET-FREE APPS (those whose .app-type names a type that provisions no
# droplet — a CLI, a library, and the gems/hex packages/OTP apps that will join
# them) have NOTHING to destroy. They created no bucket, no cluster, no droplet,
# no DNS record and no registry repository, so this script has only the code-host
# repo to offer to delete, and demands none of the DigitalOcean, DNSimple or
# Spaces credentials the rest of it needs.
#
# TENANT APPS (those with an infra/tenant/ root — apps deployed onto a droplet
# another app owns) take a different, much smaller path: their DNS record, their
# stack + volumes under /root/apps/<slug> on the droplet, and their route out of
# the shared Caddy. The droplet, its other apps, the reserved IP and the state
# bucket belong to the host and are never touched.
#
# NOT touched: the DO registry itself, the SSH key in DO, the DNSimple zone,
# the local app directory, and (without --delete-repo) the code-host repo with
# its secrets/variables.
#
# prevent_destroy guards (DB cluster, state bucket) are lifted via Terraform
# override files written for the duration of the destroy and removed after.
#
# Requires the same .env/environment as bootstrap.sh.
#
# Portable: BSD/macOS bash, grep, sed.
set -euo pipefail

# Never die silently: name the failing line/command, and stamp failed exits.
set -E
trap 'printf "teardown: failure at %s:%s\n" "${BASH_SOURCE[0]}" "$LINENO" >&2' ERR

# ---- helpers (mirror bootstrap.sh) ---------------------------------------------
fail() { printf 'teardown: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
log()  { printf '\033[31m==>\033[0m [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Same precedence rule as bootstrap.sh: the CALLING SHELL WINS. A teardown that
# silently used .env's DNS_ZONE instead of the one the operator named would
# destroy records in the wrong zone.
# shellcheck source=scripts/config.sh
. "$SCRIPT_DIR/scripts/config.sh"
load_config "$SCRIPT_DIR/.env" log

# Same provider abstraction bootstrap.sh uses (GIT_PROVIDER, is_github/
# is_gitea, repo_delete, ...) — sourced here rather than inherited, since
# teardown.sh doesn't source bootstrap.sh. Needs fail()/log()/have(), already
# defined above.
# shellcheck source=scripts/provider.sh
. "$SCRIPT_DIR/scripts/provider.sh"

# The app-type registry, for the one question this script asks it: does the app
# being torn down own any infrastructure at all? (needs_droplet, below.)
# shellcheck source=scripts/app-types.sh
. "$SCRIPT_DIR/scripts/app-types.sh"

# Modules define functions only. No destructive operation runs before confirmation.
. "$SCRIPT_DIR/scripts/teardown/environment.sh"
. "$SCRIPT_DIR/scripts/teardown/context.sh"
. "$SCRIPT_DIR/scripts/teardown/backend.sh"
. "$SCRIPT_DIR/scripts/teardown/guards.sh"
. "$SCRIPT_DIR/scripts/teardown/operations.sh"
. "$SCRIPT_DIR/scripts/teardown/plan.sh"

teardown_resolve_context "$@"
teardown_build_plan
teardown_show_plan
[ "$PLAN_ONLY" != 1 ] || exit 0
[ "${#TD_ACTIONS[@]}" -gt 0 ] || exit 0
teardown_preflight
teardown_confirm_plan
teardown_export_environment
trap 'teardown_on_exit "$?"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
teardown_execute_plan
log "teardown completed; local application source is preserved"
