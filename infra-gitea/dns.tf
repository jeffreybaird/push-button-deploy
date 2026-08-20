# Same reasoning as infra-persistent/dns.tf: the A record needs to resolve
# before Caddy's first Let's Encrypt issuance can succeed.

locals {
  is_apex    = var.dns_record == "" || var.dns_record == "@"
  gitea_fqdn = local.is_apex ? var.dns_zone : "${var.dns_record}.${var.dns_zone}"
}

resource "dnsimple_zone_record" "gitea" {
  zone_name = var.dns_zone
  name      = local.is_apex ? "" : var.dns_record
  type      = "A"
  value     = digitalocean_reserved_ip.gitea.ip_address
  ttl       = var.dns_ttl
}
