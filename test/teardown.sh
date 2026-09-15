#!/usr/bin/env bash
# Exercise the real entry point using disposable apps and command doubles.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/test/helpers/assertions.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
TOOL="$WORK/tool with spaces"
mkdir -p "$TOOL" "$WORK/bin"
cp "$ROOT/teardown.sh" "$TOOL/"
cp -R "$ROOT/scripts" "$TOOL/scripts"
for root in infra-app infra-persistent infra-state; do mkdir -p "$TOOL/$root"; done
cat > "$WORK/bin/terraform" <<'MOCK'
#!/usr/bin/env bash
set -eu
printf 'terraform %s\n' "$*" >> "$EVENTS"
root="${1#-chdir=}"; shift
case "$*" in
  'output -raw host_ip') printf '192.0.2.1\n' ;;
  'state list') printf 'digitalocean_spaces_bucket.tfstate\n' ;;
esac
case "$*" in
  destroy*)
    if [ "${root##*/}" = persistent ]; then
      grep -q 'prevent_destroy = false' "$root/teardown_override.tf" || exit 90
      [ "${FAIL_PERSISTENT:-0}" = 0 ] || exit 11
      if [ "${INTERRUPT_PERSISTENT:-0}" = 1 ]; then kill -TERM "$PPID"; fi
    fi ;;
esac
MOCK
cat > "$WORK/bin/doctl" <<'MOCK'
#!/usr/bin/env bash
printf 'doctl %s\n' "$*" >> "$EVENTS"
case "$*" in 'registry repository list-v2'*) printf 'cool_app\nneighbor_app\n';; esac
MOCK
cat > "$WORK/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "$EVENTS"
exit "${SSH_RESULT:-0}"
MOCK
cat > "$WORK/bin/gh" <<'MOCK'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$EVENTS"
MOCK
cat > "$WORK/bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 99
MOCK
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"
export DIGITALOCEAN_ACCESS_TOKEN=fixture DNSIMPLE_TOKEN=fixture DNSIMPLE_ACCOUNT=fixture DNS_ZONE=example.test
export SPACES_ACCESS_KEY_ID=fixture SPACES_SECRET_ACCESS_KEY=fixture
export SSH_PRIVATE_KEY="$WORK/key"
printf fixture > "$SSH_PRIVATE_KEY"

make_app() {
  APP="$WORK/$1/cool_app"
  mkdir -p "$APP"
  printf 'source sentinel\n' > "$APP/Gemfile"
  export EVENTS="$WORK/$1/events"
  : > "$EVENTS"
}
run_teardown() {
  result=0
  bash "$TOOL/teardown.sh" "$@" "$APP" > "$WORK/output" 2>&1 || result=$?
}
make_host() {
  make_app "$1"
  mkdir -p "$APP/infra/app/.terraform" "$APP/infra/persistent/.terraform" "$APP/infra/state/.terraform"
  printf 'key = "infra-app/terraform.tfstate"\n' > "$APP/infra/app/backend.tf"
  printf 'key = "infra-persistent/terraform.tfstate"\n' > "$APP/infra/persistent/backend.tf"
}

# Planning performs no calls, needs no credentials, and never falls back for CLI.
make_app cli
printf 'cli\n' > "$APP/.app-type"
run_teardown --plan
[ "$result" = 0 ]
[ ! -s "$EVENTS" ]
grep -q 'Nothing to destroy' "$WORK/output"
run_teardown --yes --delete-repo
[ "$result" = 0 ]
grep -q 'gh repo delete --yes' "$EVENTS"
assert_not grep -E 'terraform|doctl|ssh' "$EVENTS"

# Host scope/order and opt-in repository deletion.
make_host host
run_teardown --plan
[ "$result" = 0 ]
[ ! -s "$EVENTS" ]
run_teardown --yes
[ "$result" = 0 ] || { cat "$WORK/output"; exit 1; }
[ -f "$APP/Gemfile" ]
[ ! -e "$APP/infra/persistent/teardown_override.tf" ]
[ ! -e "$APP/infra/state/teardown_override.tf" ]
assert_not grep -q 'gh repo delete' "$EVENTS"
app_line="$(grep -n 'infra/app destroy' "$EVENTS" | cut -d: -f1)"
persistent_line="$(grep -n 'infra/persistent destroy' "$EVENTS" | cut -d: -f1)"
state_line="$(grep -n 'infra/state destroy' "$EVENTS" | cut -d: -f1)"
[ "$app_line" -lt "$persistent_line" ]
[ "$persistent_line" -lt "$state_line" ]

# Static hosts must never delete an image repository with the same name.
make_host static
rm "$APP/Gemfile"; printf 'title="site"\n' > "$APP/config.toml"
run_teardown --yes
[ "$result" = 0 ]
assert_not grep -q doctl "$EVENTS"

# Confirmation rejection makes no destructive calls.
make_host rejected
run_teardown <<< 'wrong'
[ "$result" -ne 0 ]
[ ! -s "$EVENTS" ]

# Restore user-owned overrides on failure; never reach state-bucket destruction.
for mode in failure interrupt; do
  make_host "$mode"
  printf 'existing override\n' > "$APP/infra/persistent/teardown_override.tf"
  cp "$APP/infra/persistent/teardown_override.tf" "$WORK/before"
  if [ "$mode" = failure ]; then FAIL_PERSISTENT=1 run_teardown --yes
  else INTERRUPT_PERSISTENT=1 run_teardown --yes; fi
  [ "$result" -ne 0 ]
  cmp "$WORK/before" "$APP/infra/persistent/teardown_override.tf"
  assert_not grep -q 'infra/state' "$EVENTS"
done

# Tenant plan can only reach its own root, stack, routes and image repository.
make_app tenant
mkdir -p "$APP/infra/tenant"
cat > "$APP/infra/tenant/backend.hcl" <<'HCL'
bucket = "shared-host-tfstate"
endpoints = { s3 = "https://nyc3.digitaloceanspaces.com" }
key = "tenants/cool-app/terraform.tfstate"
HCL
run_teardown --plan
[ "$result" = 0 ]
[ ! -s "$EVENTS" ]
run_teardown --yes
[ "$result" = 0 ] || { cat "$WORK/output"; exit 1; }
grep -q 'infra/tenant destroy' "$EVENTS"
grep -q 'for app in cool-app cool-app-stg' "$EVENTS"
assert_not grep -E 'infra/(state|persistent|app) |infra-state|infra-persistent|neighbor_app.*--force' "$EVENTS"
: > "$EVENTS"
SSH_RESULT=1 run_teardown --yes
[ "$result" -ne 0 ]
assert_not grep -q 'infra/tenant destroy' "$EVENTS"
# A tenant pointing at another tenant's key is refused even in plan mode.
sed 's/tenants\/cool-app/tenants\/neighbor/' "$APP/infra/tenant/backend.hcl" > "$WORK/wrong"
cp "$WORK/wrong" "$APP/infra/tenant/backend.hcl"
: > "$EVENTS"
run_teardown --plan
[ "$result" -ne 0 ]
[ ! -s "$EVENTS" ]
PROJECT_NAME='../unsafe' run_teardown --plan
[ "$result" -ne 0 ]
printf 'teardown scope, failure and cleanup checks passed\n'
