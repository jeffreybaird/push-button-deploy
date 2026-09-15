# Gitea repository lifecycle and Git authentication.

gitea_repo_exists() {
  local code
  code="$(gitea_api_status GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME")" \
    || { provider_error "Gitea repository lookup request failed"; return 2; }
  provider_repository_status "$code"
}

gitea_repo_remote_url() {
  printf '%s/%s/%s.git\n' "$GITEA_URL" "$GITEA_OWNER_RESOLVED" "$APP_NAME"
}

gitea_repo_create() {
  local body
  body="$(jq -n --arg name "$APP_NAME" '{name: $name, private: true, auto_init: false}')"
  if [ "$GITEA_OWNER_RESOLVED" = "$GITEA_AUTH_LOGIN" ]; then
    gitea_api POST "/user/repos" "$body" >/dev/null || return
  else
    gitea_api POST "/orgs/$GITEA_OWNER_RESOLVED/repos" "$body" >/dev/null || return
  fi
  # gh wires the remote as part of `repo create --remote=origin`; Gitea's API
  # only creates the repo, so the remote is added explicitly here.
  git remote get-url origin >/dev/null 2>&1 \
    || git remote add origin "$GITEA_URL/$GITEA_OWNER_RESOLVED/$APP_NAME.git"
}

gitea_repo_delete() {
  local code
  code="$(gitea_api_status DELETE "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME")" || true
  case "$code" in
    2??) : ;;
    *) fail "gitea: repo delete failed (HTTP ${code:-connection error}) — GITEA_TOKEN needs delete rights on this repo" ;;
  esac
}

# Use a transient header; never persist the token in the origin URL.
gitea_git_push() {
  git -c http.extraHeader="Authorization: token $GITEA_TOKEN" push "$@"
}
