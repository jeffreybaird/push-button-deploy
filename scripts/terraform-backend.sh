# Shared remote backend initialization. No cloud calls at source time.
# API: terraform_backend_init ROOT BUCKET ENDPOINT KEY MODE
# MODE=bootstrap migrates only local state; MODE=reconfigure never migrates.

terraform_backend_error() { printf 'terraform backend: %s\n' "$*" >&2; return 1; }

terraform_backend_key() {
  local key
  key="$(sed -nE 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"([^"]+)"[[:space:]]*(#.*)?$/\1/p' "$1/backend.tf")" || return
  [ -n "$key" ] || { terraform_backend_error "no literal backend key in $1/backend.tf; pass an explicit key"; return 1; }
  printf '%s\n' "$key"
}

terraform_backend_validate() {
  case "$1" in ''|*[!a-z0-9.-]*) terraform_backend_error "invalid state bucket"; return 1 ;; esac
  case "$2" in https://*|http://*) ;; *) terraform_backend_error "state endpoint must be an HTTP(S) URL"; return 1 ;; esac
  local value
  for value in "$2" "$3"; do
    case "$value" in ''|*'"'*|*'\'*|*'$'*|*'%'*|*$'\n'*|*$'\r'*) terraform_backend_error "invalid backend endpoint or key"; return 1 ;; esac
  done
}

terraform_backend_mode() { # cache file, bucket, endpoint, key, requested mode
  local cache="$1" bucket="$2" endpoint="$3" key="$4" mode="$5" kind same
  case "$mode" in
    reconfigure) printf '%s\n' -reconfigure; return 0 ;;
    bootstrap) ;;
    *) terraform_backend_error "mode must be bootstrap or reconfigure"; return 1 ;;
  esac
  if [ ! -f "$cache" ]; then printf '%s\n' -force-copy; return 0; fi
  kind="$(jq -er '.backend.type | select(type == "string")' "$cache" 2>/dev/null)" \
    || { terraform_backend_error "cannot read cached backend identity: $cache"; return 1; }
  case "$kind" in
    local) printf '%s\n' -force-copy ;;
    s3)
      # Validate all identity fields before choosing to discard a stale pointer.
      jq -e '.backend.config | (.bucket | type == "string") and (.key | type == "string") and
        ((.endpoints.s3 // .endpoint) | type == "string")' "$cache" >/dev/null 2>&1 \
        || { terraform_backend_error "incomplete S3 backend identity: $cache"; return 1; }
      same="$(jq -r --arg b "$bucket" --arg e "$endpoint" --arg k "$key" '
        .backend.config | .bucket == $b and .key == $k and (.endpoints.s3 // .endpoint) == $e
      ' "$cache")" || return
      if [ "$same" != true ]; then
        printf 'terraform backend: reconnecting to requested bucket/endpoint/key without migrating cached remote state\n' >&2
      fi
      # Already-remote state is never copied, including when bucket, key or
      # endpoint changed. Preserve providers, workspaces and local state files.
      printf '%s\n' -reconfigure ;;
    *) terraform_backend_error "unsupported cached backend type '$kind'; migrate it explicitly"; return 1 ;;
  esac
}

terraform_backend_write() { # root, bucket, endpoint, key
  local target="$1/backend.hcl" temporary
  [ ! -L "$target" ] || { terraform_backend_error "refusing symlink $target"; return 1; }
  temporary="$(mktemp "$1/.backend.hcl.XXXXXX")" || return
  if ! printf 'bucket = "%s"\nendpoints = { s3 = "%s" }\nkey = "%s"\n' "$2" "$3" "$4" > "$temporary"; then
    rm -f "$temporary"; return 1
  fi
  mv "$temporary" "$target" || { rm -f "$temporary"; return 1; }
}

terraform_backend_init() {
  local root="$1" bucket="$2" endpoint="$3" key="$4" mode="$5" flag data_dir
  [ -d "$root" ] || { terraform_backend_error "missing root: $root"; return 1; }
  root="$(cd "$root" && pwd)" || return
  [ -n "$key" ] || key="$(terraform_backend_key "$root")" || return
  terraform_backend_validate "$bucket" "$endpoint" "$key" || return
  data_dir="${TF_DATA_DIR:-$root/.terraform}"
  case "$data_dir" in /*) ;; *) data_dir="$root/$data_dir" ;; esac
  flag="$(terraform_backend_mode "$data_dir/terraform.tfstate" "$bucket" "$endpoint" "$key" "$mode")" || return
  terraform_backend_write "$root" "$bucket" "$endpoint" "$key" || return
  # Match the cache inspected above, including a caller's custom TF_DATA_DIR.
  local TF_DATA_DIR="$data_dir"
  export TF_DATA_DIR
  if declare -F quiet >/dev/null 2>&1; then
    quiet terraform -chdir="$root" init -input=false "$flag" -backend-config=backend.hcl
  else
    terraform -chdir="$root" init -input=false "$flag" -backend-config=backend.hcl
  fi
}
