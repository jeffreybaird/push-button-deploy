#!/usr/bin/env bash
# Scaffold a generic browser-only React app without local Node or network access.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fail() { printf 'new-react-app: %s\n' "$*" >&2; exit 1; }
APP_DIR="${1:-}"
[ -n "$APP_DIR" ] || fail 'usage: new-react-app.sh <app_dir>'
name="$(basename "$APP_DIR")"
case "$name" in
  ''|*[!a-z0-9_-]*|[!a-z]*) fail 'app directory name must start with a lowercase letter and contain lowercase letters, digits, underscores or hyphens' ;;
esac
if [ -f "$APP_DIR/package.json" ]; then
  python3 "$SCRIPT_DIR/validate-react-app.py" "$APP_DIR"
else
  if [ -d "$APP_DIR" ] && [ -n "$(ls -A "$APP_DIR")" ]; then
    fail 'directory is not empty; refusing to scaffold over existing files'
  fi
  mkdir -p "$APP_DIR"
  cp -R "$ROOT/app-react/." "$APP_DIR/"
  cp "$ROOT/test/fixtures/react/App.test.tsx" "$APP_DIR/src/App.test.tsx"
  python3 - "$APP_DIR" "$name" <<'PY'
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
for file in ('package.json', 'package-lock.json'):
    data = json.loads((root / file).read_text())
    data['name'] = sys.argv[2]
    if file == 'package-lock.json':
        data['packages']['']['name'] = sys.argv[2]
    (root / file).write_text(json.dumps(data, indent=2) + '\n')
PY
fi
. "$SCRIPT_DIR/claude-docs.sh"
cd_inject "$ROOT/app-template-react" "$APP_DIR" "$name" "$name"
printf 'React app ready: %s\nRun npm ci, npm test, npm run dev (or npm run build).\n' "$APP_DIR"
