# The same ordered operation list drives confirmation and execution.
# Parallel Bash arrays preserve paths containing spaces without eval or parsing.
teardown_add_step() {
  TD_ACTIONS[${#TD_ACTIONS[@]}]="$1"
  TD_TARGETS[${#TD_TARGETS[@]}]="$2"
  TD_LABELS[${#TD_LABELS[@]}]="$3"
}

teardown_build_plan() {
  TD_ACTIONS=(); TD_TARGETS=(); TD_LABELS=()
  if [ "$NO_INFRA" = 1 ]; then
    TD_MODE=repository_only
  elif [ "$TENANT" = 1 ]; then
    TD_MODE=tenant
    teardown_add_step tenant_backend "$TENANT_TF_DIR" "Read host address from tenant state ($STATE_BUCKET/$STATE_KEY)"
    teardown_add_step tenant_stack "$PROJECT_NAME" "Remove /root/apps/$PROJECT_NAME and $PROJECT_NAME-stg, their volumes and Caddy routes"
    teardown_add_step tenant_dns "$TENANT_TF_DIR" "Destroy tenant DNS resources in $TENANT_TF_DIR"
  else
    TD_MODE=host
    teardown_add_step host_app "$APP_TF_DIR" "Destroy droplet, firewall and IP assignment in $APP_TF_DIR"
    teardown_add_step host_persistent "$PERS_DIR" "Destroy persistent resources, INCLUDING DATABASE DATA, in $PERS_DIR"
  fi
  if [ "$NO_INFRA" != 1 ] && [ "$STATIC" != 1 ] && [ -n "$APP_NAME" ]; then
    teardown_add_step registry "$APP_NAME" "Delete image repository $APP_NAME (keep shared registry)"
  fi
  if [ "$TD_MODE" = host ]; then
    teardown_add_step host_state "$STATE_TF_DIR" "Destroy state bucket $STATE_BUCKET after app and persistent roots"
  fi
  if [ "$DELETE_REPO" = 1 ]; then
    teardown_add_step repository "$APP_DIR" "Delete $GIT_PROVIDER repository $APP_NAME"
  fi
  case "$TD_MODE" in
    tenant) teardown_add_step tenant_cache "$TENANT_TF_DIR" "Remove this tenant's local Terraform cache" ;;
    host) teardown_add_step host_cache "$STATE_TF_DIR" "Remove local backend pointers and caches for the destroyed host roots" ;;
  esac
}

teardown_show_plan() {
  local i
  printf 'TEARDOWN %s: %s\n' "$TD_MODE" "$PROJECT_NAME"
  if [ "${#TD_ACTIONS[@]}" -eq 0 ]; then printf '  Nothing to destroy.\n'; fi
  for ((i=0; i<${#TD_ACTIONS[@]}; i++)); do
    printf '  %s. %s\n' "$((i + 1))" "${TD_LABELS[$i]}"
  done
  if [ "$TD_MODE" = tenant ]; then
    printf '  Preserved: shared droplet, other apps, reserved IP, host state bucket and external backups.\n'
  fi
}

teardown_confirm_plan() {
  local answer
  [ "${#TD_ACTIONS[@]}" -gt 0 ] || return 0
  [ "$ASSUME_YES" != 1 ] || return 0
  printf 'Type the project name (%s) to confirm: ' "$PROJECT_NAME"
  read -r answer || fail "confirmation input ended; nothing destroyed"
  [ "$answer" = "$PROJECT_NAME" ] || fail "confirmation did not match; nothing destroyed"
}

teardown_execute_plan() {
  local i
  for ((i=0; i<${#TD_ACTIONS[@]}; i++)); do
    log "${TD_LABELS[$i]}"
    # Only operations declared here can execute; never execute plan text as code.
    case "${TD_ACTIONS[$i]}" in
      tenant_backend) teardown_initialize_tenant "${TD_TARGETS[$i]}" || return ;;
      tenant_stack) teardown_remove_tenant_stack "${TD_TARGETS[$i]}" || return ;;
      tenant_dns|host_app) teardown_destroy_root "${TD_TARGETS[$i]}" || return ;;
      host_persistent) teardown_destroy_persistent "${TD_TARGETS[$i]}" || return ;;
      registry) teardown_delete_registry "${TD_TARGETS[$i]}" || return ;;
      host_state) teardown_destroy_state_bucket "${TD_TARGETS[$i]}" || return ;;
      repository) (cd "${TD_TARGETS[$i]}" && repo_delete) || return ;;
      tenant_cache) rm -rf "${TD_TARGETS[$i]}/.terraform" || return ;;
      host_cache) teardown_clean_host_cache || return ;;
      *) fail "unknown teardown operation: ${TD_ACTIONS[$i]}" ;;
    esac
  done
}
