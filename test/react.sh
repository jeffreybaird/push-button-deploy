#!/usr/bin/env bash
# React service registry, static policy, scaffold, adoption and installed artifacts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/test/helpers/assertions.sh"
. "$ROOT/scripts/app-types.sh"
. "$ROOT/scripts/provider.sh"
. "$ROOT/scripts/bootstrap/config.sh"
. "$ROOT/scripts/bootstrap/app.sh"
for selection in framework typescript ts; do
  unset APP_TYPE LANGUAGE FRAMEWORK DATABASE_BACKEND ENABLE_STAGING
  APP_TYPE_FLAG=service; LANGUAGE_FLAG=""; GIT_PROVIDER=github
  if [ "$selection" = framework ]; then FRAMEWORK=react; else LANGUAGE_FLAG="$selection"; fi
  DATABASE_BACKEND=postgres; ENABLE_STAGING=true
  resolve_app_config
  [ "$APP_TYPE/$FRAMEWORK/$LANGUAGE/$DATABASE_BACKEND" = service/react/typescript/none ]
  needs_droplet
  is_static
  assert_not wants_staging
  [ "$CI_WORKFLOW" = deploy.yml ]
done
APP_DIR="$WORK/generic-app"
ensure_app
for path in package.json package-lock.json .node-version index.html tsconfig.json src/App.tsx src/main.tsx src/App.test.tsx; do
  [ -s "$APP_DIR/$path" ] || fail "missing React scaffold: $path"
done
cmp "$ROOT/test/fixtures/react/App.test.tsx" "$APP_DIR/src/App.test.tsx"
python3 - "$APP_DIR" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
p = json.loads((root/'package.json').read_text())
lock = json.loads((root/'package-lock.json').read_text())
assert p['name'] == 'generic-app'
assert all(p['scripts'].get(k) for k in ('dev', 'test', 'build'))
assert 'vite' in p['scripts']['dev'] and 'vite' in p['scripts']['build']
assert 'react' in p['dependencies'] and 'react-dom' in p['dependencies']
assert 'typescript' in p['devDependencies'] and 'vite' in p['devDependencies']
assert lock['lockfileVersion'] >= 2 and 'node_modules/react' in lock['packages']
assert lock['packages']['']['dependencies'] == p['dependencies']
assert lock['packages']['']['devDependencies'] == p['devDependencies']
PY
printf '\n// Application-owned sentinel\n' >> "$APP_DIR/src/App.tsx"
cp "$APP_DIR/src/App.tsx" "$WORK/before.tsx"
ensure_app
cmp "$WORK/before.tsx" "$APP_DIR/src/App.tsx"
for provider in github gitea; do
  prepare_app "$APP_DIR" service react none "$provider"
  cmp "$WORK/before.tsx" "$APP_DIR/src/App.tsx"
  [ "$(jq -r .framework "$APP_DIR/.agent-docs-manifest.json")" = react ]
  bash "$ROOT/agent-docs.sh" check "$APP_DIR" --json > /dev/null
  bash "$ROOT/agent-docs.sh" update "$APP_DIR" --json > /dev/null
  bash "$ROOT/agent-docs.sh" check "$APP_DIR" --json > /dev/null
  for path in deploy/publish.sh deploy/ci/remote.sh deploy/site.caddy.tmpl ".$provider/workflows/deploy.yml" ".$provider/workflows/rollback.yml"; do
    [ -s "$APP_DIR/$path" ] || fail "missing installed React artifact: $path"
  done
  for path in Dockerfile deploy/compose.yaml deploy/swap.sh ".$provider/workflows/staging.yml"; do
    [ ! -e "$APP_DIR/$path" ] || fail "unexpected server artifact: $path"
  done
  grep -Eq 'try_files.*\{path\}.*\/index.html' "$APP_DIR/deploy/site.caddy.tmpl"
  # The fallback is bounded so absent built JS/CSS do not become HTML responses.
  grep -Eq '(path|path_regexp).*([.]js|/assets/)' "$APP_DIR/deploy/site.caddy.tmpl"
  grep -Eq 'Cache-Control.*(no-cache|no-store|max-age=0)' "$APP_DIR/deploy/site.caddy.tmpl"
  grep -q '/srv/__SLUG__/current'  "$APP_DIR/deploy/site.caddy.tmpl"
  cmp "$ROOT/deploy/publish.sh" "$APP_DIR/deploy/publish.sh"
done
# Adoption is validated before writing docs/deploy files; Node alone is insufficient.
APP_DIR="$WORK/unrelated-node"; mkdir -p "$APP_DIR"
printf '{"name":"unrelated-node","scripts":{"build":"echo hello"}}\n' > "$APP_DIR/package.json"
cp "$APP_DIR/package.json" "$WORK/before.json"
if (ensure_app) > "$WORK/reject.log" 2>&1; then fail 'adopted arbitrary Node application'; fi
if (prepare_app "$APP_DIR" service react none github) > "$WORK/reject.log" 2>&1; then fail 'prepared arbitrary Node application'; fi
cmp "$WORK/before.json" "$APP_DIR/package.json"
[ ! -e "$APP_DIR/.agent-docs-manifest.json" ]
# Missing reproducible lock and missing build command both reject an otherwise real app.
for broken in lock build test malformed-lock mismatched-lock; do
  APP_DIR="$WORK/broken-$broken"; cp -R "$WORK/generic-app" "$APP_DIR"
  case "$broken" in
    lock) rm "$APP_DIR/package-lock.json" ;;
    build|test)
      jq --arg key "$broken" 'del(.scripts[$key])' "$APP_DIR/package.json" > "$WORK/package.json"
      cp "$WORK/package.json" "$APP_DIR/package.json" ;;
    malformed-lock) printf '{broken' > "$APP_DIR/package-lock.json" ;;
    mismatched-lock)
      jq '.packages[""].dependencies.react = "0.0.0"' "$APP_DIR/package-lock.json" > "$WORK/lock.json"
      cp "$WORK/lock.json" "$APP_DIR/package-lock.json" ;;
  esac
  if (ensure_app) > "$WORK/reject.log" 2>&1; then fail "adopted React app without $broken"; fi
done
# Zola keeps its genuine 404 behavior rather than receiving SPA routing.
grep -q 'rewrite @404 /404.html' "$ROOT/deploy/site.static.caddy.tmpl"
assert_not grep -q 'try_files.*index.html' "$ROOT/deploy/site.static.caddy.tmpl"
echo 'React scaffold, adoption, policy and artifact checks passed'
