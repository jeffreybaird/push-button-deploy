# The bucket both real roots keep their state in. Versioned, so every state
# revision is recoverable; prevent_destroy, because deleting it orphans the
# infrastructure records for BOTH modules.
resource "digitalocean_spaces_bucket" "tfstate" {
  name   = var.bucket_name
  region = var.region
  acl    = "private"

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}
