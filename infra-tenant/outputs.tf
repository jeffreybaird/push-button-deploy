output "domain" {
  description = "Fully-qualified domain this tenant serves on. Consumed by the shared Caddy's site file and by bootstrap's liveness poll."
  value       = local.fqdn
}

# Empty when staging is off — bootstrap reads that as "no staging environment".
output "staging_domain" {
  description = "Fully-qualified domain this tenant's PR staging environment serves on, or \"\" when staging is disabled."
  value       = local.staging_count > 0 ? local.staging_fqdn : ""
}

output "host_ip" {
  description = "Public IP of the droplet this app is a tenant of (the host's reserved IP)."
  value       = local.host_ip
}

# The tenant's CI punches its own temporary port-22 hole in the HOST's firewall
# for each deploy, exactly as the host's CI does. Surfaced here so the bootstrap
# never has to run Terraform in the host's directory.
output "firewall_id" {
  description = "Host droplet's firewall ID — CI punches a temporary port-22 hole in it per deploy."
  value       = data.terraform_remote_state.host_app.outputs.firewall_id
}

output "project_name" {
  description = "Project name — guards the same immutability check the host roots make."
  value       = var.project_name
}
