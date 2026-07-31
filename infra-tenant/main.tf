# Tenant infrastructure: everything a SECOND (third, fourth…) app needs on a
# droplet that already serves another app.
#
# Which is almost nothing — and that is the point. The host app's roots already
# own the droplet, the reserved IP, the firewall, the VPC and the tag; a tenant
# reuses all of it and adds only its own name in DNS. There is deliberately no
# droplet here: creating one would defeat the purpose, and referencing the
# host's would let `terraform destroy` on a tenant take the whole host down.
#
# The host is identified by its infra/app + infra/persistent state, read
# read-only from the shared Spaces bucket. Reading state rather than taking the
# IP as a plain input means a host that gets recreated is picked up on the next
# apply instead of quietly pointing DNS at a dead address.

data "terraform_remote_state" "host_app" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "infra-app/terraform.tfstate"
    region = "us-east-1" # required, ignored by Spaces
    endpoints = {
      s3 = var.state_endpoint
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
  }
}

locals {
  # The droplet's public address — the reserved IP, post-assignment. Every
  # tenant's A record points here, and the shared Caddy on that droplet routes
  # by Host header from there.
  host_ip = data.terraform_remote_state.host_app.outputs.app_ip

  # Apex when dns_record is "" or "@", otherwise <record>.<zone>.
  is_apex = var.dns_record == "" || var.dns_record == "@"
  fqdn    = local.is_apex ? var.dns_zone : "${var.dns_record}.${var.dns_zone}"
}

# The tenant's own name, pointed at the shared droplet. Caddy issues this app's
# certificate over HTTP-01 once this resolves, exactly as it does for the host
# app — the record must exist BEFORE the first deploy for that to work.
resource "dnsimple_zone_record" "app" {
  zone_name = var.dns_zone
  name      = local.is_apex ? "" : var.dns_record
  type      = "A"
  value     = local.host_ip
  ttl       = var.dns_ttl
}
