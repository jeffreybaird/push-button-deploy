#!/usr/bin/env bash
# Runner-side deployment operations. Source for tests or invoke one operation.
# Inputs: HOST, APP_SLUG, STACK_DIR; DOMAIN and DOCR_TOKEN where needed.
# Workflow YAML owns ordering, migrations vs rollback, and provider permissions.
set -euo pipefail

shell_words() { printf '%q ' "$@"; }
remote_ssh() { ssh -i "${DEPLOY_KEY:-$HOME/.ssh/deploy_key}" -o StrictHostKeyChecking=accept-new "root@${HOST:?HOST required}" "$@"; }
remote_scp() { scp -i "${DEPLOY_KEY:-$HOME/.ssh/deploy_key}" -o StrictHostKeyChecking=accept-new "$@"; }
remote_exec() { remote_ssh "$(shell_words "$@")"; }
remote_stack_exec() {
  remote_ssh "cd $(shell_words "${STACK_DIR:?STACK_DIR required}") && $(shell_words "$@")"
}

create_stack_directories() {
  remote_exec mkdir -p /root/caddy/sites "${STACK_DIR:?STACK_DIR required}"
}

upload_production_edge() {
  remote_scp deploy/edge-compose.yaml "root@$HOST:/root/caddy/compose.yaml"
  remote_scp deploy/Caddyfile deploy/site.caddy.tmpl deploy/edge.sh "root@$HOST:/root/caddy/"
}

# Staging can seed an empty host but must preserve production's shared files.
upload_staging_edge() {
  remote_exec mkdir -p /root/caddy/sites /root/apps /root/caddy/.incoming
  remote_scp deploy/edge-compose.yaml deploy/Caddyfile deploy/edge.sh "root@$HOST:/root/caddy/.incoming/"
  remote_ssh '
    set -e
    cd /root/caddy/.incoming
    [ -e /root/caddy/compose.yaml ] || mv edge-compose.yaml /root/caddy/compose.yaml
    [ -e /root/caddy/Caddyfile ] || mv Caddyfile /root/caddy/Caddyfile
    [ -e /root/caddy/edge.sh ] || mv edge.sh /root/caddy/edge.sh
    rm -rf /root/caddy/.incoming
  '
  remote_scp deploy/staging-down.sh "root@$HOST:/root/caddy/staging-down.sh"
  remote_scp deploy/site.caddy.tmpl "root@$HOST:/root/caddy/site.${APP_SLUG:?APP_SLUG required}.tmpl"
}

upload_stack_files() { # $1 backend, $2 environment
  local backend="$1" environment="$2" destination="root@$HOST:${STACK_DIR:?STACK_DIR required}/"
  case "$backend/$environment" in
    postgres/production|postgres/staging)
      remote_scp deploy/compose.yaml deploy/swap.sh db-ca.pem .env "$destination" ;;
    sqlite/production)
      remote_scp deploy/compose.yaml deploy/swap.sh deploy/litestream.yml .env "$destination" ;;
    sqlite/staging)
      remote_scp deploy/compose.yaml deploy/swap.sh .env "$destination"
      remote_scp deploy/litestream.staging.yml "${destination}litestream.yml"
      remote_scp deploy/compose.staging.yaml "${destination}compose.override.yaml" ;;
    *) echo "unsupported stack: $backend/$environment" >&2; return 1 ;;
  esac
}

prepare_remote_edge() { # $1 environment
  local template=site.caddy.tmpl
  case "$1" in
    production) ;;
    staging) template="site.${APP_SLUG:?APP_SLUG required}.tmpl" ;;
    *) echo "unknown environment: $1" >&2; return 1 ;;
  esac
  remote_exec env "APP_SLUG=${APP_SLUG:?APP_SLUG required}" "DOMAIN=${DOMAIN:?DOMAIN required}" \
    "SITE_TMPL=$template" bash /root/caddy/edge.sh
}

authenticate_registry() {
  printf '%s\n' "${DOCR_TOKEN:?DOCR_TOKEN required}" \
    | remote_exec docker login registry.digitalocean.com -u "$DOCR_TOKEN" --password-stdin
}

pull_runtime_image() { remote_stack_exec docker compose pull; }

run_migrations() { # $1 framework, $2 release app (Phoenix), $3 release module (Phoenix)
  case "$1" in
    phoenix) remote_stack_exec docker compose run --rm migrate "bin/${2:?app required}" eval "${3:?module required}.Release.migrate()" ;;
    sinatra) remote_stack_exec docker compose run --rm migrate bundle exec rake db:migrate ;;
    *) echo "unknown migration framework: $1" >&2; return 1 ;;
  esac
}

swap_release() { remote_exec bash "${STACK_DIR:?STACK_DIR required}/swap.sh"; }

main() {
  local operation="${1:?operation required}"; shift
  case "$operation" in
    create-directories) create_stack_directories ;;
    upload-edge) upload_production_edge ;;
    upload-staging-edge) upload_staging_edge ;;
    upload-stack) upload_stack_files "$@" ;;
    prepare-edge) prepare_remote_edge "$@" ;;
    pull-image) authenticate_registry; pull_runtime_image ;;
    migrate) run_migrations "$@" ;;
    swap) swap_release ;;
    *) echo "unknown deployment operation: $operation" >&2; return 1 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
