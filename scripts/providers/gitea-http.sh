# Gitea HTTP transport. Callers choose body mode (HTTP failures are errors)
# or status mode (HTTP status is data; connection failures remain errors).

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
