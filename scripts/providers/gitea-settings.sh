# Gitea Actions secrets and variables. secret_set consumes stdin.
# Variable deletion remains best effort for compatibility with teardown.

gitea_secret_set() {
  local name="$1"
  local value body
  value="$(cat)"
  body="$(jq -n --arg data "$value" '{data: $data}')"
  gitea_api PUT "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/secrets/$name" "$body" >/dev/null
}

gitea_var_set() {
  local name="$1" value="$2"
  local body code
  body="$(jq -n --arg value "$value" '{value: $value}')"
  code="$(gitea_api_status PUT "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/variables/$name" "$body")" || true
  case "$code" in
    2??) return 0 ;;
    404)
      code="$(gitea_api_status POST "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/variables/$name" "$body")" || true
      case "$code" in
        2??) return 0 ;;
        *) fail "gitea: could not create variable $name (HTTP ${code:-connection error})" ;;
      esac ;;
    *) fail "gitea: could not set variable $name (HTTP ${code:-connection error})" ;;
  esac
}

gitea_var_delete() {
  local name="$1"
  gitea_api_status DELETE "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/variables/$name" >/dev/null 2>&1 || true
}
