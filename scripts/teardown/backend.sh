# Teardown reconnects to existing remote state; it never copies state.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/terraform-backend.sh"
backend_init() {
  terraform_backend_init "$1" "$STATE_BUCKET" "$STATE_ENDPOINT" "${2:-}" reconfigure
}
