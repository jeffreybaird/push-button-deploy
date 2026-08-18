# scripts/tfstate.sh — Spaces state-bucket bootstrap, shared by bootstrap.sh
# (per-app state bucket) and bootstrap-gitea.sh (Gitea's own state bucket).
# Extracted rather than duplicated because ensure_state_bucket()'s fallback
# path (direct S3 API bucket creation when Terraform reports success but the
# API still 404s — a DO provider quirk observed in the wild) is exactly the
# kind of subtle, hard-won logic that duplicating invites drift on.
#
# Requires from the sourcing script: fail(), warn(), log(), quiet(), $LOG_FILE
# already defined. Requires from the caller: PROJECT_NAME, REGION,
# STATE_TF_DIR, DIGITALOCEAN_ACCESS_TOKEN, SPACES_ACCESS_KEY_ID,
# SPACES_SECRET_ACCESS_KEY already set; STATE_BUCKET/SPACES_REGION optional
# (defaulted here). Sets STATE_REGION/STATE_BUCKET/STATE_ENDPOINT as a side
# effect of ensure_state_bucket().

# Ensure the Spaces state bucket exists. This tiny root keeps LOCAL state on
# purpose — the bucket can't store the state that creates it.
ensure_state_bucket() {
  # The s3 backend + remote_state reads authenticate with the AWS env names.
  export AWS_ACCESS_KEY_ID="$SPACES_ACCESS_KEY_ID"
  export AWS_SECRET_ACCESS_KEY="$SPACES_SECRET_ACCESS_KEY"

  STATE_REGION="${SPACES_REGION:-$REGION}"
  STATE_BUCKET="${STATE_BUCKET:-${PROJECT_NAME}-tfstate}"
  STATE_ENDPOINT="https://${STATE_REGION}.digitaloceanspaces.com"

  export TF_VAR_do_token="$DIGITALOCEAN_ACCESS_TOKEN"
  export TF_VAR_spaces_access_id="$SPACES_ACCESS_KEY_ID"
  export TF_VAR_spaces_secret_key="$SPACES_SECRET_ACCESS_KEY"
  export TF_VAR_bucket_name="$STATE_BUCKET"
  export TF_VAR_region="$STATE_REGION"

  log "terraform: infra-state (Spaces bucket '$STATE_BUCKET' in $STATE_REGION)"
  log "init infra-state (output in $LOG_FILE)..."
  quiet terraform -chdir="$STATE_TF_DIR" init -input=false

  # This root keeps LOCAL state (the bucket can't store the state that creates
  # it) — per-project workspaces, or a second project silently inherits the
  # first project's bucket in the shared state file.
  quiet terraform -chdir="$STATE_TF_DIR" workspace select -or-create "$PROJECT_NAME"

  # Adopt a bucket that exists but isn't in this workspace's state yet (e.g.
  # created by the direct-API fallback below, or a previous half-run) — apply
  # would otherwise die on BucketAlreadyExists.
  if ! terraform -chdir="$STATE_TF_DIR" state list 2>/dev/null | grep -q . && bucket_visible; then
    log "importing existing bucket '$STATE_BUCKET' into infra-state ($PROJECT_NAME workspace)"
    quiet terraform -chdir="$STATE_TF_DIR" import -input=false \
      digitalocean_spaces_bucket.tfstate "${STATE_REGION},${STATE_BUCKET}"
  fi

  terraform -chdir="$STATE_TF_DIR" apply -auto-approve -input=false

  # The bucket must answer the S3 API before any backend references it. An
  # unsigned request to a private bucket returns 403 once it exists, 404 while
  # it doesn't. Two failure modes feed this: plain propagation lag, and a DO
  # provider bug observed in the wild where apply reports the bucket created
  # (and refreshes cleanly!) while the S3 API keeps 404ing — for that one we
  # fall back to creating the bucket via the S3 API directly.
  if ! wait_bucket_visible 18; then
    warn "terraform reports bucket '$STATE_BUCKET' but the S3 API 404s it — creating it via the S3 API directly"
    quiet curl -fsS -o /dev/null --max-time 15 -X PUT \
      --aws-sigv4 "aws:amz:${STATE_REGION}:s3" \
      --user "${SPACES_ACCESS_KEY_ID}:${SPACES_SECRET_ACCESS_KEY}" \
      "${STATE_ENDPOINT}/${STATE_BUCKET}/"
    printf '<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>' \
      | quiet curl -fsS -o /dev/null --max-time 15 -X PUT \
          --aws-sigv4 "aws:amz:${STATE_REGION}:s3" \
          --user "${SPACES_ACCESS_KEY_ID}:${SPACES_SECRET_ACCESS_KEY}" \
          -T - "${STATE_ENDPOINT}/${STATE_BUCKET}/?versioning"
    wait_bucket_visible 6 \
      || fail "state bucket $STATE_BUCKET still not visible after direct creation — check Spaces status, then re-run"
  fi
  log "state bucket ready: $STATE_BUCKET"
}

# True once the bucket answers the S3 API (200/403 = exists, 404 = not yet).
bucket_visible() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "https://${STATE_BUCKET}.${STATE_REGION}.digitaloceanspaces.com/" || true)"
  [ "$code" = "200" ] || [ "$code" = "403" ]
}

wait_bucket_visible() { # $1: attempts, 5s apart
  local i
  for i in $(seq 1 "$1"); do
    bucket_visible && return 0
    log "  bucket not visible yet (attempt $i/$1)"
    sleep 5
  done
  return 1
}

# Point a root at the Spaces backend and init. -force-copy migrates any
# existing local state into the bucket on first contact (idempotent after).
# $2 (optional): state key, for roots that don't pin one in backend.tf. The host
# roots each own a fixed key because they are alone in their bucket; tenants
# share the HOST's bucket, so every tenant needs a key of its own.
backend_init() {
  # A cached backend from a previous project may point at a bucket that no
  # longer exists (torn down) — init would try to migrate state OUT of it and
  # die on the 404. If the cached bucket differs from the current one, drop
  # the cache and start clean.
  local cached
  cached="$(sed -nE 's/.*"bucket": ?"([^"]+)".*/\1/p' "$1/.terraform/terraform.tfstate" 2>/dev/null | head -1 || true)"
  if [ -n "$cached" ] && [ "$cached" != "$STATE_BUCKET" ]; then
    log "backend: cached bucket '$cached' != '$STATE_BUCKET' — reinitializing $(basename "$1")"
    rm -rf "$1/.terraform"
  fi
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  if [ -n "${2:-}" ]; then
    printf 'key       = "%s"\n' "$2" >> "$1/backend.hcl"
  fi
  log "backend: init $(basename "$1") against $STATE_BUCKET (may download providers; output in $LOG_FILE)..."
  quiet terraform -chdir="$1" init -input=false -force-copy -backend-config=backend.hcl
  log "backend: $(basename "$1") initialized"
}
