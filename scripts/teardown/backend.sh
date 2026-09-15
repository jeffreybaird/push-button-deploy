# Remote backend initialization; replaced by shared helper in the next PR.
backend_init() {
  cat > "$1/backend.hcl" <<EOF
bucket    = "$STATE_BUCKET"
endpoints = { s3 = "$STATE_ENDPOINT" }
EOF
  terraform -chdir="$1" init -input=false -force-copy -backend-config=backend.hcl >/dev/null
}

