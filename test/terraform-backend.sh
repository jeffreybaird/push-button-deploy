#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
. "$ROOT/scripts/terraform-backend.sh"
root="$WORK/root with spaces"
mkdir -p "$root/.terraform/providers"
printf 'key = "infra-app/terraform.tfstate"\n' > "$root/backend.tf"
printf 'provider cache\n' > "$root/.terraform/providers/keep"
printf 'local state\n' > "$root/terraform.tfstate"
terraform() { printf '%s\n' "$@" > "$WORK/args"; printf '%s' "$TF_DATA_DIR" > "$WORK/data-dir"; return "${INIT_STATUS:-0}"; }
check_flag() { grep -Fx -- "$1" "$WORK/args" >/dev/null; }
init() { terraform_backend_init "$root" state-bucket https://nyc3.digitaloceanspaces.com "${1:-}" "${2:-bootstrap}"; }
cache() {
  jq -n --arg b "$1" --arg k "$2" --arg e "$3" \
    '{backend:{type:"s3",config:{bucket:$b,key:$k,endpoints:{s3:$e}}}}' > "$root/.terraform/terraform.tfstate"
}
init
check_flag -force-copy
grep -Fx 'key = "infra-app/terraform.tfstate"' "$root/backend.hcl"
printf '{"backend":{"type":"local"}}' > "$root/.terraform/terraform.tfstate"
init
check_flag -force-copy
# Existing remote state is reconnected, never copied, for each identity change.
for identity in same bucket key endpoint; do
  bucket=state-bucket; key=infra-app/terraform.tfstate; endpoint=https://nyc3.digitaloceanspaces.com
  case "$identity" in bucket) bucket=old-bucket ;; key) key=tenants/other/terraform.tfstate ;; endpoint) endpoint=https://sfo3.digitaloceanspaces.com ;; esac
  cache "$bucket" "$key" "$endpoint"
  init
  check_flag -reconfigure
  [ "$(cat "$root/.terraform/providers/keep")" = 'provider cache' ]
  [ "$(cat "$root/terraform.tfstate")" = 'local state' ]
done
# Legacy endpoint cache representation is supported.
printf '{"backend":{"type":"s3","config":{"bucket":"state-bucket","key":"infra-app/terraform.tfstate","endpoint":"https://nyc3.digitaloceanspaces.com"}}}' > "$root/.terraform/terraform.tfstate"
init
check_flag -reconfigure
# Bootstrap refuses unreadable/unsupported identity before any config mutation.
for invalid in 'not json' '{"backend":{"type":"s3","config":{}}}' '{"backend":{"type":"azurerm"}}'; do
  printf '%s' "$invalid" > "$root/.terraform/terraform.tfstate"
  printf 'unchanged\n' > "$root/backend.hcl"
  rm -f "$WORK/args"
  if init; then exit 1; fi
  [ ! -e "$WORK/args" ]
  [ "$(cat "$root/backend.hcl")" = unchanged ]
done
# Teardown always reconnects, even with stale metadata, and preserves tenant key.
init tenants/my-app/terraform.tfstate reconfigure
check_flag -reconfigure
grep -Fx 'key = "tenants/my-app/terraform.tfstate"' "$root/backend.hcl"
# Relative and absolute custom data directories match the inspected cache.
for custom in 'custom cache' "$WORK/absolute cache"; do
  TF_DATA_DIR="$custom"
  case "$custom" in /*) expected="$custom" ;; *) expected="$root/$custom" ;; esac
  mkdir -p "$expected"
  printf '{"backend":{"type":"local"}}' > "$expected/terraform.tfstate"
  init
  check_flag -force-copy
  [ "$(cat "$WORK/data-dir")" = "$expected" ]
  [ "$TF_DATA_DIR" = "$custom" ]
done
unset TF_DATA_DIR
# Invalid input and symlink destinations never invoke Terraform.
for invalid_key in 'bad"key' 'bad${key}' $'bad\nkey'; do
  rm -f "$WORK/args"
  if terraform_backend_init "$root" state-bucket https://example.com "$invalid_key" bootstrap; then exit 1; fi
  [ ! -e "$WORK/args" ]
done
rm "$root/backend.hcl"
printf 'keep\n' > "$WORK/target"
ln -s "$WORK/target" "$root/backend.hcl"
if init tenant/key reconfigure; then exit 1; fi
[ "$(cat "$WORK/target")" = keep ]
rm "$root/backend.hcl"
# Both direct and quiet execution preserve the Terraform failure status.
INIT_STATUS=17
status=0; init tenant/key reconfigure || status=$?
[ "$status" -eq 17 ]
quiet() { "$@"; }
status=0; init tenant/key reconfigure || status=$?
[ "$status" -eq 17 ]
printf 'terraform backend contracts passed\n'
