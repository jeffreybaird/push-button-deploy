#!/usr/bin/env bash
# Offline runtime serialization and remote delivery checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$ROOT/deploy/ci/runtime-env.sh"
. "$ROOT/deploy/ci/remote.sh"
IMAGE=registry/app:abc; DOMAIN=example.invalid; APP_SLUG=example
DATABASE_URL=ecto://user:password@db/staging; DATABASE_PATH=/data/app.sqlite3
SECRET_KEY_BASE='literal $(touch SHOULD_NOT_EXIST) `touch ALSO_NOT` $value "quoted"'
LITESTREAM_ACCESS_KEY_ID=key; LITESTREAM_SECRET_ACCESS_KEY=secret
BACKUP_BUCKET=backup; BACKUP_ENDPOINT=https://spaces.invalid; BACKUP_REGION=nyc3; BACKUP_PATH=db
APP_ENV=$'CUSTOM_VALUE=literal $(echo nope)\nOTHER_VALUE=two words'
for backend in postgres sqlite; do
  for environment in production staging; do
    file="$WORK/$backend-$environment.env"
    write_runtime_env "$backend" "$environment" "$file"
    grep -Fxq "IMAGE=$IMAGE" "$file"
    grep -Fxq "SECRET_KEY_BASE=$SECRET_KEY_BASE" "$file"
    [ "$(tail -2 "$file")" = "$APP_ENV" ]
    if [ "$backend" = postgres ]; then
      grep -Fxq "DATABASE_URL=$DATABASE_URL" "$file"
      assert_not grep -q '^DATABASE_PATH=' "$file"
    else
      grep -Fxq "DATABASE_PATH=$DATABASE_PATH" "$file"
      assert_not grep -q '^DATABASE_URL=' "$file"
    fi
    if [ "$backend/$environment" = sqlite/production ]; then
      grep -Fxq "LITESTREAM_SECRET_ACCESS_KEY=$LITESTREAM_SECRET_ACCESS_KEY" "$file"
    else
      assert_not grep -Eq '^(LITESTREAM_|BACKUP_)' "$file"
    fi
    # BSD and GNU stat spell file permissions differently.
    mode="$(stat -f %Lp "$file" 2>/dev/null || stat -c %a "$file")"
    [ "$mode" = 600 ]
  done
done
DATABASE_URL=""
if write_runtime_env postgres staging "$WORK/invalid.env"; then exit 1; fi

mkdir -p "$WORK/app/deploy"
cp "$ROOT"/deploy/*.* "$ROOT/deploy/Caddyfile" "$WORK/app/deploy/"
cd "$WORK/app"
HOST=host.invalid; STACK_DIR=/root/apps/example-stg; APP_SLUG=example-stg
SIMULATE=1
remote_ssh() {
  printf 'ssh %s\n' "$*" >> "$WORK/calls"
  if [ "$SIMULATE" = 1 ]; then
    local command="$1"
    command="${command//\/root/$WORK/host}"
    bash -c "$command"
  fi
}
remote_scp() {
  printf 'scp %s\n' "$*" >> "$WORK/calls"
  if [ "$SIMULATE" = 1 ]; then
    local destination="${!#}" source
    destination="${destination#root@$HOST:}"
    destination="${destination//\/root/$WORK/host}"
    while [ "$#" -gt 1 ]; do source="$1"; shift; cp "$source" "$destination"; done
  fi
}
mkdir -p "$WORK/host/caddy"
printf 'production owns this\n' > "$WORK/host/caddy/Caddyfile"
# Missing files are seeded, existing production configuration is preserved.
upload_staging_edge
[ "$(cat "$WORK/host/caddy/Caddyfile")" = 'production owns this' ]
cmp deploy/edge-compose.yaml "$WORK/host/caddy/compose.yaml"
cmp deploy/site.caddy.tmpl "$WORK/host/caddy/site.example-stg.tmpl"
[ ! -e "$WORK/host/caddy/site.caddy.tmpl" ]

mkdir -p "$WORK/host/apps/example-stg"
printf 'runtime\n' > .env
cp deploy/compose.sqlite.yaml deploy/compose.yaml
upload_stack_files sqlite staging
cmp deploy/compose.staging.yaml "$WORK/host/apps/example-stg/compose.override.yaml"
cmp deploy/litestream.staging.yml "$WORK/host/apps/example-stg/litestream.yml"

SIMULATE=0
prepare_remote_edge staging
run_migrations phoenix example Example
swap_release
grep -Fq SITE_TMPL=site.example-stg.tmpl "$WORK/calls"
grep -Fq 'docker compose run --rm migrate bin/example eval' "$WORK/calls"
grep -Fq '/root/apps/example-stg/swap.sh' "$WORK/calls"
# Quoting remains correct when a path contains spaces or shell punctuation.
quoted="$(shell_words 'two words' 'literal;$value')"
[ "$(bash -c "printf '%s|%s' $quoted")" = 'two words|literal;$value' ]
echo 'workflow script checks passed'
