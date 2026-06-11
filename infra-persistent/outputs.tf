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

output "database_ca_cert" {
  description = "Cluster CA certificate (PEM) — shipped to the droplet so the app verifies the DB server cert."
  value       = data.digitalocean_database_ca.pg.certificate
  sensitive   = true
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

# Admin (doadmin) URL for the APP database over the private host. PG15+ gives
# the app user no CREATE on schema public (doadmin owns it via the DO API), so
# bootstrap runs a one-time GRANT through the droplet — the only host the DB
# firewall trusts.
output "database_admin_url" {
  description = "doadmin connection URL for the app DB (private host). Used to grant schema privileges."
  value = format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    digitalocean_database_cluster.pg.user,
    urlencode(digitalocean_database_cluster.pg.password),
    digitalocean_database_cluster.pg.private_host,
    digitalocean_database_cluster.pg.port,
    digitalocean_database_db.app.name,
  )
  sensitive = true
}
