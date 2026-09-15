# Terraform environment setup is separate from ownership selection and execution.
teardown_read_tenant_backend() {
  local hcl
  hcl="$TENANT_TF_DIR/backend.hcl"
  [ -f "$hcl" ] || fail "no $hcl — run the bootstrap on this app once before tearing it down"
  STATE_BUCKET="$(sed -nE 's/^bucket[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  STATE_ENDPOINT="$(sed -nE 's/.*s3[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  STATE_KEY="$(sed -nE 's/^key[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$hcl" | head -1)"
  [ -n "$STATE_BUCKET" ] && [ -n "$STATE_ENDPOINT" ] && [ -n "$STATE_KEY" ] \
    || fail "could not read bucket/endpoint/key from $hcl"
  [ "$STATE_KEY" = "tenants/$PROJECT_NAME/terraform.tfstate" ] || fail "tenant state key does not belong to $PROJECT_NAME"

}

teardown_export_environment() {
  [ "$NO_INFRA" != 1 ] || return 0
  if [ "$TENANT" = 1 ]; then
    export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
    export TF_VAR_project_name="$PROJECT_NAME"
    export TF_VAR_state_bucket="$STATE_BUCKET"
    export TF_VAR_state_endpoint="$STATE_ENDPOINT"
    export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
    export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
    export TF_VAR_dns_zone="$DNS_ZONE"
    export TF_VAR_dns_record="${DNS_RECORD:-$PROJECT_NAME}"

  else
    export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"
    export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
    export TF_VAR_project_name="$PROJECT_NAME"
    export TF_VAR_region="$REGION"
    export TF_VAR_dnsimple_token="$DNSIMPLE_TOKEN"
    export TF_VAR_dnsimple_account="$DNSIMPLE_ACCOUNT"
    export TF_VAR_dns_zone="$DNS_ZONE"
    export TF_VAR_dns_record="${DNS_RECORD:-}"
    export TF_VAR_ssh_key_name="${SSH_KEY_NAME:-}"
    export TF_VAR_ssh_cidrs='["127.0.0.1/32"]'   # destroy needs the var, not the value
    export TF_VAR_gitea_runner_cidr='[]'          # ditto — destroy doesn't care what it was
    export TF_VAR_state_bucket="$STATE_BUCKET"
    export TF_VAR_state_endpoint="$STATE_ENDPOINT"
    export TF_VAR_spaces_access_id="$SPACES_ACCESS_KEY_ID"
    export TF_VAR_spaces_secret_key="$SPACES_SECRET_ACCESS_KEY"
    export TF_VAR_bucket_name="$STATE_BUCKET"

  fi
}
