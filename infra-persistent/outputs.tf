output "reserved_ip" {
  description = "Stable public IP that survives droplet recreation. Assigned to the droplet in infra-app."
  value       = digitalocean_reserved_ip.this.ip_address
}

output "vpc_id" {
  description = "VPC ID consumed by infra-app via terraform_remote_state."
  value       = digitalocean_vpc.this.id
}

# ecto:// URL over the PRIVATE host (VPC-internal). Password is urlencoded since
# DO-generated passwords may contain URL-reserved characters. Empty when the
# backend is SQLite (no managed cluster exists); try() turns the index-out-of-
# range on the count=0 resources into that empty string.
output "database_url" {
  description = "Ecto connection URL for the app DB over the private VPC host. Empty on the SQLite backend."
  value = try(format(
    "ecto://%s:%s@%s:%d/%s",
    digitalocean_database_user.app[0].name,
    urlencode(digitalocean_database_user.app[0].password),
    digitalocean_database_cluster.pg[0].private_host,
    digitalocean_database_cluster.pg[0].port,
    digitalocean_database_db.app[0].name,
  ), "")
  sensitive = true
}

output "database_ca_cert" {
  description = "Cluster CA certificate (PEM) — shipped to the droplet so the app verifies the DB server cert. Empty on the SQLite backend."
  value       = try(data.digitalocean_database_ca.pg[0].certificate, "")
  sensitive   = true
}

output "database_backend" {
  description = "Which database backend this project was provisioned with ('postgres' or 'sqlite')."
  value       = var.database_backend
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
  description = "doadmin connection URL for the app DB (private host). Used to grant schema privileges. Empty on the SQLite backend."
  value = try(format(
    "postgresql://%s:%s@%s:%d/%s?sslmode=require",
    digitalocean_database_cluster.pg[0].user,
    urlencode(digitalocean_database_cluster.pg[0].password),
    digitalocean_database_cluster.pg[0].private_host,
    digitalocean_database_cluster.pg[0].port,
    digitalocean_database_db.app[0].name,
  ), "")
  sensitive = true
}
