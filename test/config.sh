#!/usr/bin/env bash
# Offline precedence, secret-redaction, shell-portability and policy checks.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$ROOT/scripts/config.sh"
report_override() { printf '%s\n' "$*" >> "$WORK/overrides"; }
cat > "$WORK/config with spaces.env" <<'CONFIG'
TEST_SECRET='file-secret-never-log'
export TEST_EMPTY='file-default'
TEST_MULTILINE='file-value'
TEST_NEW='new value'
TEST_NEW='last assignment wins'
TEST_EXPANDED="$TEST_NEW/suffix"
CONFIG
TEST_SECRET='caller-secret-never-log'
TEST_EMPTY=''
TEST_MULTILINE=$'literal $(touch NOT_EXECUTED) `touch NEITHER` $value "quotes"\nsecond line'
expected_multiline="$TEST_MULTILINE"
load_config "$WORK/config with spaces.env" report_override
[ "$TEST_SECRET" = caller-secret-never-log ]
[ "$TEST_EMPTY" = '' ]
[ "$TEST_MULTILINE" = "$expected_multiline" ]
[ "$TEST_NEW" = 'last assignment wins' ]
[ "$TEST_EXPANDED" = 'last assignment wins/suffix' ]
[ "$(bash -c 'printf %s "$TEST_SECRET"')" = caller-secret-never-log ]
[ "$(wc -l < "$WORK/overrides" | tr -d ' ')" = 3 ]
assert_not grep -Eq 'never-log|file-default|file-value|NOT_EXECUTED' "$WORK/overrides"
case $- in *a*) echo 'loader changed allexport' >&2; exit 1 ;; esac
load_config "$WORK/missing.env" report_override
(
  set -a
  load_config "$WORK/config with spaces.env"
  case $- in *a*) ;; *) exit 1 ;; esac
)
# No existing assignments: arrays must work under macOS Bash 3.2 with nounset.
(
  unset TEST_SECRET TEST_EMPTY TEST_MULTILINE TEST_NEW TEST_EXPANDED
  load_config "$WORK/config with spaces.env"
  [ "$TEST_SECRET" = file-secret-never-log ]
)

log() { :; }
warn() { printf '%s\n' "$*" >&2; }
fail() { printf '%s\n' "$*" >&2; exit 1; }
. "$ROOT/scripts/app-types.sh"
. "$ROOT/scripts/provider.sh"
. "$ROOT/scripts/bootstrap/config.sh"
contains() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
for provider in github gitea; do
  for spec in 'service phoenix elixir' 'service sinatra ruby' 'service zola static' \
              'cli escript elixir' 'cli ruby-cli ruby' 'cli bash-cli bash' \
              'cli ts-cli typescript' 'library mix elixir'; do
    (
      read -r APP_TYPE FRAMEWORK LANGUAGE <<< "$spec"
      GIT_PROVIDER="$provider"; DATABASE_BACKEND=postgres; ENABLE_STAGING=true
      TOTAL_STEPS=sentinel
      resolve_app_config
      [ "$TOTAL_STEPS" = sentinel ]
      if [ "$APP_TYPE" != service ]; then
        [ "$DATABASE_BACKEND" = none ]
        assert_not contains "$REQUIRED_BINS" terraform
        assert_not contains "$REQUIRED_ENV" DIGITALOCEAN_ACCESS_TOKEN
        assert_not contains "$REQUIRED_ENV" GITEA_RUNNER_IP
      else
        contains "$REQUIRED_BINS" terraform
        contains "$REQUIRED_ENV" DIGITALOCEAN_ACCESS_TOKEN
        if [ "$FRAMEWORK" = phoenix ]; then [ "$DATABASE_BACKEND" = postgres ]
        elif [ "$FRAMEWORK" = sinatra ]; then [ "$DATABASE_BACKEND" = sqlite ]
        else [ "$DATABASE_BACKEND" = none ]; fi
      fi
      if [ "$provider" = github ]; then
        contains "$REQUIRED_BINS" gh
        assert_not contains "$REQUIRED_ENV" GITEA_TOKEN
      else
        contains "$REQUIRED_BINS" jq
        contains "$REQUIRED_ENV" GITEA_TOKEN
      fi
    )
  done
done
if (FRAMEWORK=phoenix; APP_TYPE=service; ENABLE_STAGING=maybe; resolve_app_config); then
  echo 'invalid staging configuration accepted' >&2; exit 1
fi
if (FRAMEWORK=phoenix; APP_TYPE=service; DATABASE_BACKEND=unknown; resolve_app_config); then
  echo 'invalid database configuration accepted' >&2; exit 1
fi
(
  unset APP_TYPE FRAMEWORK LANGUAGE DATABASE_BACKEND ENABLE_STAGING
  APP_TYPE_FLAG=cli; LANGUAGE_FLAG=ruby
  resolve_app_config
  [ "$FRAMEWORK" = ruby-cli ]
  [ "$CI_WORKFLOW" = ci.yml ]
)
# Exercise the real entry point without the developer's .env or live accounts.
mkdir -p "$WORK/tool" "$WORK/bin"
cp "$ROOT/bootstrap.sh" "$WORK/tool/"
cp -R "$ROOT/scripts" "$WORK/tool/scripts"
cat > "$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
[ "$*" = 'auth status' ] || { echo 'unexpected GitHub call' >&2; exit 1; }
MOCK
chmod +x "$WORK/bin/gh"
printf "TEST_SECRET='file-secret-never-log'\n" > "$WORK/tool/.env"
PATH="$WORK/bin:$PATH" TF_PLUGIN_CACHE_DIR="$WORK/cache" \
  bash "$WORK/tool/bootstrap.sh" --check --cli ruby "$WORK/app" > "$WORK/entry-output" 2>&1
grep -q 'preflight: OK' "$WORK/entry-output"
assert_not grep -q 'never-log' "$WORK/entry-output"
assert_not grep -q 'never-log' "$WORK/tool/bootstrap.log"
[ ! -d "$WORK/app" ]
echo 'config checks passed'
