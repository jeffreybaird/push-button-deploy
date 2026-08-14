# DNS at DNSimple (not DO). The A record lives in the persistent module so the
# name resolves to the reserved IP BEFORE the droplet exists — Caddy needs the
# record live to issue the first Let's Encrypt cert (story 4.2).

locals {
  # Apex when dns_record is "" or "@", otherwise <record>.<zone>.
  is_apex = var.dns_record == "" || var.dns_record == "@"
  fqdn    = local.is_apex ? var.dns_zone : "${var.dns_record}.${var.dns_zone}"

  # The STAGING name, for the environment a pull request against main stands up
  # on this same droplet (deploy/staging-down.sh, .github/workflows/staging.yml).
  # On the apex the app has no label of its own to extend, so the project name
  # supplies one — the record must never be the apex itself.
  staging_label = local.is_apex ? "${var.project_name}-stg" : "${var.dns_record}-stg"
  staging_fqdn  = "${local.staging_label}.${var.dns_zone}"

  # A static site has no server-side environment to stand up (no container, no
  # database, and its whole "deploy" is a symlink), so it never gets a staging
  # name even when the flag is left on.
  staging_count = var.enable_staging && var.database_backend != "none" ? 1 : 0
}

resource "dnsimple_zone_record" "app" {
  zone_name = var.dns_zone
  name      = local.is_apex ? "" : var.dns_record
  type      = "A"
  value     = digitalocean_reserved_ip.this.ip_address
  ttl       = var.dns_ttl
}

# The staging name, pointed at the SAME droplet as production — the shared Caddy
# routes the two apart by Host header, exactly as it does for two different apps.
#
# The record is declared here, not created by CI, for the same reason the app's
# own record is: a name that must resolve before Caddy can issue a certificate
# belongs in Terraform, and keeping it here means the deploy pipeline never needs
# DNSimple credentials. It is therefore STABLE — a PR builds and destroys the
# environment behind this name, not the name itself.
resource "dnsimple_zone_record" "staging" {
  count     = local.staging_count
  zone_name = var.dns_zone
  name      = local.staging_label
  type      = "A"
  value     = digitalocean_reserved_ip.this.ip_address
  ttl       = var.dns_ttl
}
