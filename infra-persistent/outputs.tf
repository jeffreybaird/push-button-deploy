output "reserved_ip" {
  description = "Stable public IP that survives droplet recreation. Assigned to the droplet in infra-app."
  value       = digitalocean_reserved_ip.this.ip_address
}

output "vpc_id" {
  description = "VPC ID consumed by infra-app via terraform_remote_state."
  value       = digitalocean_vpc.this.id
}

# ecto:// URL over the PRIVATE host (VPC-internal). Password is urlencoded since
# DO-generated passwords may contain URL-reserved characters.
output "database_url" {
  description = "Ecto connection URL for the app DB over the private VPC host."
  value = format(
    "ecto://%s:%s@%s:%d/%s",
    digitalocean_database_user.app.name,
    urlencode(digitalocean_database_user.app.password),
    digitalocean_database_cluster.pg.private_host,
    digitalocean_database_cluster.pg.port,
    digitalocean_database_db.app.name,
  )
  sensitive = true
}

# The tag string infra-app must apply to the droplet so the DB firewall trusts it.
output "db_trusted_tag" {
  description = "Tag the droplet must wear to pass the managed-Postgres firewall."
  value       = digitalocean_tag.app.name
}

output "domain" {
  description = "Fully-qualified domain the app serves on. Consumed by Caddy/bootstrap."
  value       = local.fqdn
}

output "region" {
  description = "Region slug — infra-app pins the droplet to the same region as the reserved IP."
  value       = var.region
}

output "project_name" {
  description = "Project name — infra-app derives the droplet name from it."
  value       = var.project_name
}
