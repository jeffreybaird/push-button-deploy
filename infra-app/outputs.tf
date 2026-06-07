output "droplet_id" {
  description = "ID of the app droplet."
  value       = digitalocean_droplet.app.id
}

output "app_ip" {
  description = "Public IP the app is reachable on (the reserved IP, post-assignment)."
  value       = local.reserved_ip
}

output "trusted_tag" {
  description = "Tag the droplet wears — must equal the DB firewall's trusted tag."
  value       = data.digitalocean_tag.app.name
}
