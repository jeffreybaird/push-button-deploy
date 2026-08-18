# scripts/provider.sh — code-hosting + CI/CD provider abstraction.
#
# Sourced by both bootstrap.sh and teardown.sh, AFTER their .env is sourced:
# GIT_PROVIDER is resolved here the same way bootstrap.sh resolves FRAMEWORK/
# DATABASE_BACKEND — after .env, so a shell override still wins (see the
# precedence comment in bootstrap.sh).
#
# GitHub (the default) is untouched by this file's existence: every shim below
# reduces to the exact `gh` invocation the two scripts already ran before this
# abstraction existed. Gitea (self-hosted, GIT_PROVIDER=gitea) talks to the
# instance's REST API directly over `curl` — no `tea` CLI, no dependency
# beyond `curl` (already required) and `jq` (required only for this path: safe
# JSON body construction, and parsing Actions run status).
#
# Every provider if/else lives HERE — preflight/ensure_repo/seed_ci/run_state/
# diagnose in bootstrap.sh (and teardown.sh's repo delete) call these shims and
# stay provider-agnostic themselves.
#
# Requires from the sourcing script: fail(), log(), have() already defined.
# Callers of the repo/secret/var/run shims must have $APP_NAME set first (and
# $HEAD_SHA for ci_run_row); ci_auth_check must run before any of them (it
# resolves $GITEA_OWNER_RESOLVED).

GIT_PROVIDER="${GIT_PROVIDER:-github}"
case "$GIT_PROVIDER" in
  github|gitea) ;;
  *) fail "GIT_PROVIDER must be 'github' or 'gitea' (got '$GIT_PROVIDER')" ;;
esac
is_github() { [ "$GIT_PROVIDER" = "github" ]; }
is_gitea()  { [ "$GIT_PROVIDER" = "gitea" ]; }

# Always-defined (possibly empty) so later expansions are safe under set -u
# regardless of provider; preflight's REQUIRED_ENV loop is what actually
# enforces these are non-empty when is_gitea.
GITEA_URL="${GITEA_URL:-}"
GITEA_TOKEN="${GITEA_TOKEN:-}"
GITEA_OWNER="${GITEA_OWNER:-}"
GITEA_RUNNER_IP="${GITEA_RUNNER_IP:-}"
GITEA_URL="${GITEA_URL%/}"   # normalize: no trailing slash

# ---- Gitea REST helpers -------------------------------------------------------

# Low-level call: prints the response body, fails (curl -f) on a non-2xx status.
gitea_api() { # $1 method, $2 path (e.g. /repos/x/y), $3 body (optional JSON)
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -X "$method" \
      -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$GITEA_URL/api/v1$path"
  else
    curl -fsS -X "$method" \
      -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
      "$GITEA_URL/api/v1$path"
  fi
}

# Same call, but returns the HTTP status code instead of failing/printing the
# body — used where the caller must branch on 404 vs 2xx (variable
# create-vs-update) rather than treat every non-2xx as fatal.
gitea_api_status() { # $1 method, $2 path, $3 body (optional)
  local method="$1" path="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
      -d "$body" "$GITEA_URL/api/v1$path"
  else
    curl -sS -o /dev/null -w '%{http_code}' -X "$method" \
      -H "Authorization: token $GITEA_TOKEN" -H "Content-Type: application/json" \
      "$GITEA_URL/api/v1$path"
  fi
}

# ---- provider shims -------------------------------------------------------

# Confirms the provider credentials work; for Gitea this also resolves the
# owner ($GITEA_OWNER_RESOLVED) every later {owner}/{repo} call uses — the
# same way `gh repo create` implicitly acts as whichever account is
# `gh auth login`'d, so two people running bootstrap.sh with their own
# GITEA_TOKEN each get repos under their own account with no config change.
# GITEA_OWNER, if set, overrides this (create under an org instead of the
# token's own user).
ci_auth_check() {
  if is_github; then
    gh auth status >/dev/null 2>&1 || fail "gh not authenticated — run: gh auth login"
    return 0
  fi
  GITEA_AUTH_LOGIN="$(gitea_api GET /user 2>/dev/null | jq -r '.login // empty')" || true
  [ -n "$GITEA_AUTH_LOGIN" ] \
    || fail "Gitea auth failed — check GITEA_URL/GITEA_TOKEN ($GITEA_URL/api/v1/user)"
  GITEA_OWNER_RESOLVED="${GITEA_OWNER:-$GITEA_AUTH_LOGIN}"
}

repo_exists() {
  if is_github; then
    gh repo view >/dev/null 2>&1
  else
    [ "$(gitea_api_status GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME")" = "200" ]
  fi
}

repo_create() {
  if is_github; then
    gh repo create "$APP_NAME" --source=. --private --remote=origin
    return
  fi
  local body
  body="$(jq -n --arg name "$APP_NAME" '{name: $name, private: true, auto_init: false}')"
  if [ "$GITEA_OWNER_RESOLVED" = "$GITEA_AUTH_LOGIN" ]; then
    gitea_api POST "/user/repos" "$body" >/dev/null
  else
    gitea_api POST "/orgs/$GITEA_OWNER_RESOLVED/repos" "$body" >/dev/null
  fi
  # gh wires the remote as part of `repo create --remote=origin`; Gitea's API
  # only creates the repo, so the remote is added explicitly here.
  git remote get-url origin >/dev/null 2>&1 \
    || git remote add origin "$GITEA_URL/$GITEA_OWNER_RESOLVED/$APP_NAME.git"
}

repo_delete() {
  if is_github; then
    gh repo delete --yes \
      || fail "gh repo delete failed — it needs the delete_repo scope: gh auth refresh -h github.com -s delete_repo"
    return 0
  fi
  local code
  code="$(gitea_api_status DELETE "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME")" || true
  case "$code" in
    2??) : ;;
    *) fail "gitea: repo delete failed (HTTP ${code:-connection error}) — GITEA_TOKEN needs delete rights on this repo" ;;
  esac
}

# Push the current branch, injecting Gitea auth as a transient HTTP header
# rather than an embedded-credential remote URL — the token never lands in
# .git/config on disk. GitHub is unchanged (relies on gh's own credentials).
provider_git_push() {
  if is_gitea; then
    git -c http.extraHeader="Authorization: token $GITEA_TOKEN" push "$@"
  else
    git push "$@"
  fi
}

# secret_set NAME — reads the secret's VALUE FROM STDIN, never as an argument
# (keeps it out of `ps`, and out of any command transcript). Same call shape
# `gh secret set NAME` already used (it also reads stdin).
secret_set() {
  local name="$1"
  if is_github; then
    gh secret set "$name"
    return
  fi
  local value body
  value="$(cat)"
  body="$(jq -n --arg data "$value" '{data: $data}')"
  gitea_api PUT "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/secrets/$name" "$body" >/dev/null
}

# var_set NAME VALUE — non-secret config; the value is not sensitive, so
# (like the `gh variable set NAME -b VALUE` this replaces) it's a plain arg.
var_set() {
  local name="$1" value="$2"
  if is_github; then
    gh variable set "$name" -b "$value"
    return
  fi
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

# var_delete NAME — remove a variable, silently tolerating "was not there".
# Used to retract a switch (STAGING_DOMAIN) that must not outlive the thing it
# switched on; absence is the desired end state either way, so no error path.
var_delete() {
  local name="$1"
  if is_github; then
    gh variable delete "$name" >/dev/null 2>&1 || true
    return 0
  fi
  gitea_api_status DELETE "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/variables/$name" >/dev/null 2>&1 || true
}

# The newest deploy run for the commit just pushed, normalized to GitHub's
# "id status conclusion" shape (confirm_live()'s case statement is written
# against the last two fields) — Gitea's Actions API reports a single `status`
# field instead of GitHub's status+conclusion split, so it's mapped here rather
# than at the call site. Empty until the provider has registered the run.
#
# The id leads: bootstrap remembers the run that already existed before it
# triggered anything, so a stale conclusion from an earlier attempt is never
# mistaken for this invocation's verdict (see run_state in bootstrap.sh).
#
# GITEA CAVEAT: /actions/tasks is the broadest-compatible run-listing endpoint
# across recent Gitea releases. Newer Gitea also exposes a more GitHub-shaped
# /actions/workflows/{id}/runs endpoint that may suit your version better —
# verify against the actual target instance (README: "Gitea support") before
# relying on this for anything beyond bootstrap's own liveness poll.
ci_run_row() {
  if is_github; then
    ( cd "$APP_DIR" \
      && gh run list --workflow deploy.yml --commit "$HEAD_SHA" --limit 1 \
           --json databaseId,status,conclusion \
           --jq '.[0] | "\(.databaseId) \(.status) \(.conclusion)"' 2>/dev/null
    ) || true
    return 0
  fi
  local row id status
  row="$(gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/tasks" 2>/dev/null \
    | jq -r --arg sha "$HEAD_SHA" '
        (.workflow_runs // .) as $runs
        | [$runs[]? | select(.head_sha == $sha)]
        | sort_by(.run_number // .id) | last
        | "\(.id // "")\t\(.status // "")"
      ' 2>/dev/null)" || true
  id="${row%%	*}"
  status="${row#*	}"
  [ -n "$id" ] || return 0
  case "$status" in
    success)                   printf '%s completed success\n'   "$id" ;;
    failure)                   printf '%s completed failure\n'   "$id" ;;
    cancelled)                 printf '%s completed cancelled\n' "$id" ;;
    skipped)                   printf '%s completed skipped\n'   "$id" ;;
    running|waiting|blocked)   printf '%s in_progress \n'        "$id" ;;
    *) : ;;
  esac
}

# Start deploy.yml against main WITHOUT a new commit. A bootstrap re-run that
# fixed something outside git pushes nothing, so no push event fires and no
# deploy starts; this is what gets one going. Both providers expose a workflow
# dispatch, so neither path has to fake a commit to redeploy.
ci_dispatch_deploy() {
  if is_github; then
    ( cd "$APP_DIR" && gh workflow run deploy.yml --ref main ) \
      || fail "could not dispatch deploy.yml (gh workflow run) — trigger it by hand: gh workflow run deploy.yml --ref main"
    return 0
  fi
  local code body
  body='{"ref":"main"}'
  code="$(gitea_api_status POST \
    "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/workflows/deploy.yml/dispatches" "$body")" || true
  case "$code" in
    2??) return 0 ;;
    *) fail "gitea: could not dispatch deploy.yml (HTTP ${code:-connection error}) — trigger it by hand from $GITEA_URL/$GITEA_OWNER_RESOLVED/$APP_NAME/actions" ;;
  esac
}

# Human-facing pointer to where to go look at CI run detail/logs. GitHub: the
# `gh` subcommands the README already documents. Gitea: the repo's Actions
# URL — no first-party CLI is assumed installed, so a URL is the reliable one.
ci_watch_hint() { is_gitea && printf '%s/%s/%s/actions' "$GITEA_URL" "$GITEA_OWNER_RESOLVED" "$APP_NAME" || printf 'gh run watch'; }
ci_log_hint()   { is_gitea && printf '%s/%s/%s/actions' "$GITEA_URL" "$GITEA_OWNER_RESOLVED" "$APP_NAME" || printf 'gh run view --log-failed'; }

# Ordered diagnostics' first section (Actions status) — provider-specific list.
ci_diagnose_dump() {
  if is_github; then
    ( cd "$APP_DIR" && gh run list --workflow deploy.yml --limit 3 ) || echo "(gh run list failed)"
    return 0
  fi
  gitea_api GET "/repos/$GITEA_OWNER_RESOLVED/$APP_NAME/actions/tasks?limit=3" 2>/dev/null \
    | jq -r '
        (.workflow_runs // .) as $runs
        | $runs[:3][]
        | "\(.id)\t\(.status)\t\((.head_sha // "")[0:8])\t\(.run_started_at // .created_at // "")"
      ' \
    || echo "(gitea actions task list failed)"
}
