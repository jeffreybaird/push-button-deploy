output "gitea_ip" {
  description = "Reserved public IP the Gitea host is reachable on (also GITEA_RUNNER_IP, since the runner is co-located)."
  value       = digitalocean_reserved_ip.gitea.ip_address
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
