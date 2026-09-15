# Authenticate and resolve the repository owner before repository operations.
# Gitea 1.24 is required for Actions workflow dispatch (task polling needs 1.23).
GITEA_MIN_VERSION="1.24"

gitea_version_at_least() { # $1 have, $2 want -> 0 if have >= want
  awk -v have="$1" -v want="$2" 'BEGIN {
    n = split(have, h, "."); m = split(want, w, ".")
    for (i = 1; i <= 3; i++) {
      hv = (i <= n ? h[i] + 0 : 0); wv = (i <= m ? w[i] + 0 : 0)
      if (hv > wv) exit 0
      if (hv < wv) exit 1
    }
    exit 0
  }'
}

gitea_ci_auth_check() {
  GITEA_AUTH_LOGIN="$(gitea_api GET /user 2>/dev/null | jq -r '.login // empty')" || true
  [ -n "$GITEA_AUTH_LOGIN" ] \
    || fail "Gitea auth failed — check GITEA_URL/GITEA_TOKEN ($GITEA_URL/api/v1/user)"
  GITEA_OWNER_RESOLVED="${GITEA_OWNER:-$GITEA_AUTH_LOGIN}"

  local ver
  ver="$(gitea_api GET /version 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
  [ -n "$ver" ] \
    || fail "Gitea did not report a version ($GITEA_URL/api/v1/version) — cannot confirm it is at least $GITEA_MIN_VERSION"
  gitea_version_at_least "$ver" "$GITEA_MIN_VERSION" \
    || fail "Gitea $ver is too old — this tool needs at least $GITEA_MIN_VERSION.
  Below $GITEA_MIN_VERSION the Actions API has no /actions/tasks (run polling) and no
  /actions/workflows/{id}/dispatches (redeploy trigger), so a deploy can be
  started but never confirmed. Secrets and variables work either way, which is
  why this only surfaces at the deploy step without this check.
  Fix: bump the gitea image tag in gitea-host/docker-compose.yaml and re-run
  ./bootstrap-gitea.sh (data lives on the volume; the upgrade is in place)."
}
