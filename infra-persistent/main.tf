# Persistent infrastructure: VPC + reserved IP.
# These outlive the droplet. Managed Postgres (1.2) and DNS (1.3) append here.

resource "digitalocean_vpc" "this" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_ip_range
}

# Reserved IP is created region-only (UNASSIGNED). The droplet assignment lives
# in infra-app (story 2.1) so destroying the droplet never releases this IP.
resource "digitalocean_reserved_ip" "this" {
  region = var.region

  lifecycle {
    prevent_destroy = true
  }
}
