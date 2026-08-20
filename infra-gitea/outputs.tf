output "gitea_ip" {
  description = "Reserved public IP the Gitea host is reachable on — what DNS points at and what you browse/clone to. NOT the address the runner connects OUT from; see gitea_egress_ip."
  value       = digitalocean_reserved_ip.gitea.ip_address
}

# The address an app's firewall has to allow-list, and it is NOT the reserved
# IP above. Per DigitalOcean's docs, attaching a reserved IP "doesn't replace
# or change" the droplet's original public IP, and outbound traffic keeps
# using that original address unless the default gateway is manually
# re-pointed at the anchor IP. So a rule written against the reserved IP
# allow-lists an address the co-located runner never dials out from — the app
# droplet drops its SSH, and the deploy job dies at the first ssh-keyscan.
#
# This changes when the droplet is REPLACED (--replace-droplet), while the
# reserved IP deliberately does not. After a replace, re-run ./bootstrap.sh
# for each app so its firewall picks up the new value.
output "gitea_egress_ip" {
  description = "Public IP the Gitea droplet's outbound traffic originates from — this is GITEA_RUNNER_IP. Changes if the droplet is replaced."
  value       = digitalocean_droplet.gitea.ipv4_address
}

output "domain" {
  description = "Fully-qualified domain Gitea serves on. This is GITEA_URL's host (https://<domain>)."
  value       = local.gitea_fqdn
}

output "droplet_id" {
  description = "ID of the Gitea droplet."
  value       = digitalocean_droplet.gitea.id
}

output "firewall_id" {
  description = "Gitea droplet's firewall ID."
  value       = digitalocean_firewall.gitea.id
}

output "data_volume_id" {
  description = "ID of the persistent data volume (SQLite DB + repos + Actions logs)."
  value       = digitalocean_volume.gitea_data.id
}
