# Resolve identity and ownership from local inputs. No remote operations.
teardown_parse_args() {
  local app_arg=0
  ASSUME_YES=0; DELETE_REPO=0; PLAN_ONLY=0; APP_DIR=.
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) ASSUME_YES=1 ;;
      --delete-repo) DELETE_REPO=1 ;;
      --plan) PLAN_ONLY=1 ;;
      -*) fail "unknown argument: $1 (use --plan, --yes, --delete-repo, [app_dir])" ;;
      *) [ "$app_arg" = 0 ] || fail "only one app_dir may be supplied"; APP_DIR="$1"; app_arg=1 ;;
    esac
    shift
  done
  [ -d "$APP_DIR" ] || fail "app directory does not exist: $APP_DIR"
  APP_DIR="$(cd "$APP_DIR" && pwd)"
}

teardown_read_app_identity() {
  APP_TYPE=service
  if [ -f "$APP_DIR/.app-type" ]; then APP_TYPE="$(tr -d '[:space:]' < "$APP_DIR/.app-type")"; fi
  [ -n "$(app_type_row "$APP_TYPE")" ] || fail "unknown app type '$APP_TYPE'"
  APP_NAME=""; STATIC=0
  if [ -f "$APP_DIR/mix.exs" ]; then
    . "$SCRIPT_DIR/scripts/app-meta.sh"
    APP_NAME="$(app_name "$APP_DIR")"
  elif [ -f "$APP_DIR/Gemfile" ]; then
    APP_NAME="$(basename "$APP_DIR")"
  elif [ -f "$APP_DIR/config.toml" ]; then
    APP_NAME="$(basename "$APP_DIR")"; STATIC=1
  fi
  if [ -z "${PROJECT_NAME:-}" ]; then
    [ -n "$APP_NAME" ] || fail "PROJECT_NAME not set and no app name can be derived"
    PROJECT_NAME="$(printf '%s' "$APP_NAME" | tr '_' '-')"
  fi
  case "$PROJECT_NAME" in
    ''|*[!a-z0-9-]*|-*|*-) fail "invalid PROJECT_NAME: use lowercase letters, digits and inner hyphens" ;;
  esac
  if [ "$DELETE_REPO" = 1 ]; then [ -n "$APP_NAME" ] || fail "--delete-repo needs an app name"; fi
}

teardown_resolve_roots() {
  local root
  NO_INFRA=0; TENANT=0
  TENANT_TF_DIR="$APP_DIR/infra/tenant"
  if ! needs_droplet; then
    NO_INFRA=1
    return 0
  fi
  if [ -d "$TENANT_TF_DIR" ]; then
    [ ! -d "$APP_DIR/infra/state" ] || fail "ambiguous ownership: both tenant and host roots exist"
    TENANT=1
    teardown_read_tenant_backend
    return
  fi
  if [ -d "$APP_DIR/infra/state" ]; then
    PERS_DIR="$APP_DIR/infra/persistent"; APP_TF_DIR="$APP_DIR/infra/app"; STATE_TF_DIR="$APP_DIR/infra/state"
  else
    # Retain the legacy roots for apps created before per-app infra copies.
    PERS_DIR="$SCRIPT_DIR/infra-persistent"; APP_TF_DIR="$SCRIPT_DIR/infra-app"; STATE_TF_DIR="$SCRIPT_DIR/infra-state"
  fi
  for root in "$PERS_DIR" "$APP_TF_DIR" "$STATE_TF_DIR"; do
    [ -d "$root" ] || fail "missing Terraform root: $root"
  done
  REGION="${REGION:-nyc3}"
  STATE_REGION="${SPACES_REGION:-$REGION}"
  STATE_BUCKET="${STATE_BUCKET:-${PROJECT_NAME}-tfstate}"
  STATE_ENDPOINT="https://${STATE_REGION}.digitaloceanspaces.com"
}

teardown_derive_requirements() {
  REQUIRED_BINS=""; REQUIRED_ENV=""
  if [ "$NO_INFRA" != 1 ]; then
    REQUIRED_BINS="terraform doctl jq"
    REQUIRED_ENV="DIGITALOCEAN_ACCESS_TOKEN DNSIMPLE_TOKEN DNSIMPLE_ACCOUNT DNS_ZONE SPACES_ACCESS_KEY_ID SPACES_SECRET_ACCESS_KEY"
  fi
  if [ "$TENANT" = 1 ]; then
    REQUIRED_BINS="$REQUIRED_BINS ssh"
    REQUIRED_ENV="$REQUIRED_ENV SSH_PRIVATE_KEY"
  fi
  if [ "$DELETE_REPO" = 1 ]; then
    if is_gitea; then
      REQUIRED_BINS="$REQUIRED_BINS curl jq"
      REQUIRED_ENV="$REQUIRED_ENV GITEA_URL GITEA_TOKEN"
    else
      REQUIRED_BINS="$REQUIRED_BINS gh"
    fi
  fi
}

teardown_resolve_context() {
  teardown_parse_args "$@"
  teardown_read_app_identity
  teardown_resolve_roots
  teardown_derive_requirements
}

teardown_preflight() {
  local bin key value
  for bin in $REQUIRED_BINS; do have "$bin" || fail "missing binary: $bin"; done
  for key in $REQUIRED_ENV; do
    value="${!key:-}"
    [ -n "$value" ] || fail "missing env var: $key"
  done
  if [ "$TENANT" = 1 ]; then [ -r "$SSH_PRIVATE_KEY" ] || fail "SSH private key not readable: $SSH_PRIVATE_KEY"; fi
  if [ "$DELETE_REPO" = 1 ]; then ci_auth_check; fi
}
