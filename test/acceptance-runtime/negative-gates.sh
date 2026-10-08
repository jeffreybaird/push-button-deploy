#!/usr/bin/env bash
# Execute only against a generated scratch application with installed dependencies.
# Copy code explicitly: no .env, local databases, logs, infra or credentials.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SOURCE="${1:?generated app required}"
KIND="${2:?sinatra, phoenix, mix or escript required}"
case "$KIND" in sinatra|phoenix|mix|escript) ;; *) exit 2 ;; esac
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/app"
for path in app lib config test spec features assets priv views public bin support script \
  Gemfile Gemfile.lock mix.exs mix.lock .formatter.exs .ruby-version .tool-versions \
  .rspec app.rb config.ru Rakefile; do
  [ ! -e "$SOURCE/$path" ] || cp -R "$SOURCE/$path" "$WORK/app/$path"
done
# Elixir dependency/build caches are generated artifacts; reuse read-only inputs.
[ ! -d "$SOURCE/deps" ] || cp -R "$SOURCE/deps" "$WORK/app/deps"
[ ! -d "$SOURCE/_build" ] || cp -R "$SOURCE/_build" "$WORK/app/_build"
mkdir -p "$WORK/app/db" "$WORK/app/tmp" "$WORK/app/log"
if [ -d "$SOURCE/db/migrate" ]; then cp -R "$SOURCE/db/migrate" "$WORK/app/db/migrate"; fi
cd "$WORK/app"
export MIX_ENV=test RACK_ENV=test
unset DATABASE_PATH DATABASE_URL PRIMARY_DATABASE_URL
if [ "$KIND" = sinatra ]; then
  printf 'production database sentinel\n' > "$WORK/production.db"
  cp "$WORK/production.db" "$WORK/expected.db"
  DATABASE_PATH="$WORK/production.db" DATABASE_URL="sqlite://$WORK/production.db" PRIMARY_DATABASE_URL="sqlite://$WORK/production.db" \
    bundle exec rspec --format documentation
  cmp "$WORK/expected.db" "$WORK/production.db"
  DATABASE_PATH="$WORK/production.db" DATABASE_URL="sqlite://$WORK/production.db" PRIMARY_DATABASE_URL="sqlite://$WORK/production.db" \
    ./bin/check-features
  cmp "$WORK/expected.db" "$WORK/production.db"
else
  ./bin/check-features
fi
for mode in undefined failing pending; do
  cp "$ROOT/test/fixtures/acceptance/negative/$mode.feature" features/negative.feature
  if [ "$mode" != undefined ]; then
    suffix=ex; [ "$KIND" != sinatra ] || suffix=rb
    cp "$ROOT/test/fixtures/acceptance/negative/${mode}_steps.$suffix" "features/step_definitions/${mode}_steps.$suffix"
  fi
  status=0
  ./bin/check-features > "$WORK/output" 2>&1 || status=$?
  cat "$WORK/output"
  [ "$status" -ne 0 ] || { echo "$KIND $mode gate unexpectedly passed" >&2; exit 1; }
  if [ "$mode" = failing ]; then grep -qi 'fail\|assert' "$WORK/output"; else grep -qi "$mode" "$WORK/output"; fi
  rm features/negative.feature
  [ "$mode" = undefined ] || rm "features/step_definitions/${mode}_steps.$suffix"
done
printf '%s strict undefined, pending and failing acceptance gates verified\n' "$KIND"
