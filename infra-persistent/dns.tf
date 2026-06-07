# DNS at DNSimple (not DO). The A record lives in the persistent module so the
# name resolves to the reserved IP BEFORE the droplet exists — Caddy needs the
# record live to issue the first Let's Encrypt cert (story 4.2).

locals {
  # Apex when dns_record is "" or "@", otherwise <record>.<zone>.
  is_apex = var.dns_record == "" || var.dns_record == "@"
  fqdn    = local.is_apex ? var.dns_zone : "${var.dns_record}.${var.dns_zone}"
}

resource "dnsimple_zone_record" "app" {
  zone_name = var.dns_zone
  name      = local.is_apex ? "" : var.dns_record
  type      = "A"
  value     = digitalocean_reserved_ip.this.ip_address
  ttl       = var.dns_ttl
}
