# Public code-host and CI API. Source after config resolution; requires fail().
# Adapter files only define functions: sourcing never authenticates or writes.
# See providers/README.md for inputs, outputs and error behavior.
CI_WORKFLOW="${CI_WORKFLOW:-deploy.yml}"
GIT_PROVIDER="${GIT_PROVIDER:-github}"
GITEA_URL="${GITEA_URL:-}"
GITEA_URL="${GITEA_URL%/}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GITEA_OWNER="${GITEA_OWNER:-}"
GITEA_RUNNER_IP="${GITEA_RUNNER_IP:-}"

provider_validate() {
  case "$GIT_PROVIDER" in
    github|gitea) ;;
    *) fail "GIT_PROVIDER must be 'github' or 'gitea' (got '$GIT_PROVIDER')" ;;
  esac
}
provider_validate
is_github() { [ "$GIT_PROVIDER" = github ]; }
is_gitea() { [ "$GIT_PROVIDER" = gitea ]; }

PROVIDER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/providers" && pwd)"
. "$PROVIDER_LIB_DIR/errors.sh"
. "$PROVIDER_LIB_DIR/github.sh"
. "$PROVIDER_LIB_DIR/gitea-http.sh"
. "$PROVIDER_LIB_DIR/gitea-auth.sh"
. "$PROVIDER_LIB_DIR/gitea-repository.sh"
. "$PROVIDER_LIB_DIR/gitea-settings.sh"
. "$PROVIDER_LIB_DIR/gitea-runs.sh"

# Dispatch in the caller's shell so resolved auth state, stdin and exit status
# survive. Fixed wrapper operation names and validated provider names need no eval.
provider_call() {
  local operation="$1"
  shift
  provider_validate
  "${GIT_PROVIDER}_${operation}" "$@"
}

ci_auth_check() { provider_call ci_auth_check; }
repo_exists() { provider_call repo_exists; }
repo_remote_url() { provider_call repo_remote_url; }
repo_create() { provider_call repo_create; }
repo_delete() { provider_call repo_delete; }
provider_git_push() { provider_call git_push "$@"; }
secret_set() { provider_call secret_set "$@"; }
var_set() { provider_call var_set "$@"; }
var_delete() { provider_call var_delete "$@"; }

# Optional explicit arguments override caller context only for this query.
# Bash locals are visible in adapter functions and restored on return.
ci_run_row() {
  local APP_DIR="${1:-${APP_DIR:-}}" CI_WORKFLOW="${2:-$CI_WORKFLOW}" HEAD_SHA="${3:-${HEAD_SHA:-}}"
  provider_call ci_run_row
}
ci_dispatch_deploy() { provider_call ci_dispatch_deploy; }
ci_watch_hint() { provider_call ci_watch_hint; }
ci_log_hint() { provider_call ci_log_hint; }
ci_diagnose_dump() { provider_call ci_diagnose_dump; }
