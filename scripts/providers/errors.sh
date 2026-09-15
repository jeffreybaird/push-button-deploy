# Shared query contract: 0 success, 1 provider-reported absence, 2 request error.
provider_error() { printf 'provider: %s\n' "$*" >&2; return 2; }

provider_repository_status() { # HTTP code
  case "$1" in
    200) return 0 ;;
    404) return 1 ;;
    *) provider_error "repository lookup failed (HTTP ${1:-unavailable}); origin was not changed" ;;
  esac
}

provider_delete_status() { # resource label, HTTP code
  case "$2" in
    2??|404) return 0 ;;
    *) provider_error "could not delete $1 (HTTP ${2:-unavailable})" ;;
  esac
}
