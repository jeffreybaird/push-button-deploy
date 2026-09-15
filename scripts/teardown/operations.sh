# Individual teardown operations. All inputs are resolved before execution.

teardown_initialize_tenant() {
  backend_init "$1" "$STATE_KEY" || return
  DROPLET_IP="$(terraform -chdir="$1" output -raw host_ip)" || return
  [ -n "$DROPLET_IP" ] || fail "tenant state has no host_ip; refusing to discard DNS before cleanup"
  case "$DROPLET_IP" in *[!0-9a-fA-F:.]*) fail "invalid host_ip in tenant state" ;; esac
}

teardown_remove_tenant_stack() {
  local slug="$1"
  # PROJECT_NAME was validated before the plan; it is also the compose slug.
  ssh -i "$SSH_PRIVATE_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 \
    "root@$DROPLET_IP" "
      set -e
      for app in $slug $slug-stg; do
        if [ -f /root/apps/\$app/compose.yaml ]; then
          (cd /root/apps/\$app && docker compose down -v --remove-orphans)
        fi
        rm -rf /root/apps/\$app /root/caddy/sites/\$app.caddy
      done
      cd /root/caddy
      docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
    " || { log "tenant cleanup failed; DNS and state are preserved for retry"; return 1; }
}

teardown_destroy_root() {
  if [ "$TD_MODE" = host ]; then backend_init "$1" || return; fi
  terraform -chdir="$1" destroy -auto-approve -input=false
}

teardown_destroy_persistent() {
  backend_init "$1" || return
  teardown_lift_guard "$1" digitalocean_database_cluster pg || return
  teardown_lift_guard "$1" digitalocean_reserved_ip this || return
  terraform -chdir="$1" destroy -auto-approve -input=false
}

teardown_delete_registry() {
  local repos
  # Query failures are not proof of absence. Stop instead of deleting the state
  # bucket while an owned resource could remain.
  repos="$(doctl registry repository list-v2 --format Name --no-header)" || return
  if printf '%s\n' "$repos" | grep -Fxq "$1"; then
    doctl registry repository delete "$1" --force || return
  fi
}

teardown_destroy_state_bucket() {
  local root="$1" resources
  terraform -chdir="$root" init -input=false >/dev/null || return
  terraform -chdir="$root" workspace select -or-create "$PROJECT_NAME" >/dev/null || return
  resources="$(terraform -chdir="$root" state list)" || return
  if [ -z "$resources" ]; then
    terraform -chdir="$root" import -input=false \
      digitalocean_spaces_bucket.tfstate "${STATE_REGION},${STATE_BUCKET}" >/dev/null || return
  fi
  teardown_lift_guard "$root" digitalocean_spaces_bucket tfstate 'force_destroy = true' || return
  terraform -chdir="$root" apply -auto-approve -input=false >/dev/null || return
  terraform -chdir="$root" destroy -auto-approve -input=false || return
  terraform -chdir="$root" workspace select default >/dev/null || return
  terraform -chdir="$root" workspace delete "$PROJECT_NAME" >/dev/null
}

teardown_clean_host_cache() {
  rm -f "$PERS_DIR/backend.hcl" "$APP_TF_DIR/backend.hcl" || return
  rm -rf "$PERS_DIR/.terraform" "$APP_TF_DIR/.terraform" "$STATE_TF_DIR/.terraform" || return
  rm -f "$STATE_TF_DIR/terraform.tfstate" "$STATE_TF_DIR/terraform.tfstate.backup"
}
