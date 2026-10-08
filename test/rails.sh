#!/usr/bin/env bash
# Scaffold generation and strict existing-app adoption without local Rails gems.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$ROOT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
log() { :; }
warn() { :; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/app-types.sh"
. "$ROOT/scripts/bootstrap/app.sh"
APP_TYPE=service; FRAMEWORK=rails; APP_DIR="$WORK/shop_api"
[ "$(framework_signature service rails)" = config/application.rb ]
ensure_app
for path in Gemfile .ruby-version config/application.rb config/environment.rb config/boot.rb \
            config/database.yml config/puma.rb config/routes.rb config.ru Rakefile bin/rails \
            test/test_helper.rb test/integration/health_test.rb; do
  [ -s "$APP_DIR/$path" ] || fail "missing Rails scaffold $path"
done
[ -x "$APP_DIR/bin/rails" ]
[ "$(read_app_identity "$APP_DIR" service rails ruby)" = 'shop_api|ShopApi' ]
grep -q 'Rails::Application' "$APP_DIR/config/application.rb"
grep -q 'DATABASE_PATH' "$APP_DIR/config/database.yml"
grep -q sqlite3 "$APP_DIR/config/database.yml"
# Litestream replication requires WAL; inspect generated database configuration.
ruby - "$APP_DIR" <<'RUBY'
root = ARGV.fetch(0)
configuration = ([File.join(root, 'config/database.yml')] + Dir[File.join(root, 'config/initializers/*.rb')]).map { |p| File.read(p) }.join("\n")
abort 'Rails SQLite must explicitly select WAL for Litestream' unless configuration.match?(/journal_mode/i) && configuration.match?(/\bwal\b/i)
RUBY
grep -q '/health' "$APP_DIR/config/routes.rb"
cmp "$ROOT/test/fixtures/rails/health_test.rb" "$APP_DIR/test/integration/health_test.rb"
cmp "$ROOT/test/fixtures/rails/test_helper.rb" "$APP_DIR/test/test_helper.rb"
while IFS= read -r -d '' file; do ruby -c "$file" >/dev/null; done < <(find "$APP_DIR" -name '*.rb' -print0)
ruby -c "$APP_DIR/bin/rails" >/dev/null
ruby -c "$APP_DIR/Gemfile" >/dev/null
# Generation/adoption reruns preserve application code.
printf '\n# application owned sentinel\n' >> "$APP_DIR/config/application.rb"
cp "$APP_DIR/config/application.rb" "$WORK/original.rb"
ensure_app
cmp "$WORK/original.rb" "$APP_DIR/config/application.rb"
# A Sinatra or unrelated Ruby Gemfile must never be mistaken for Rails.
APP_DIR="$WORK/not_rails"; mkdir -p "$APP_DIR"
printf 'source "https://rubygems.org"\n' > "$APP_DIR/Gemfile"
if (ensure_app) > "$WORK/rejected.log" 2>&1; then fail 'adopted Gemfile-only directory as Rails'; fi
grep -q 'config/application.rb' "$WORK/rejected.log"
[ "$(cat "$APP_DIR/Gemfile")" = 'source "https://rubygems.org"' ]
[ ! -e "$APP_DIR/config/application.rb" ]
echo 'Rails scaffold and adoption checks passed'
