# Every app gets its own DigitalOcean project, named after the app, so its
# resources are grouped together in the DO control panel instead of landing in
# the account default. The project lives here (not infra-app) because it must
# outlive the droplet, like everything else in this root.
#
# Only URN-addressable resources can join a project: the reserved IP, the
# managed Postgres cluster, the Spaces bucket and the droplet. VPCs, tags and
# firewalls have no URN and always live account-wide; the DNS record is at
# DNSimple, outside DO entirely. The droplet is attached from infra-app (its
# own state) so destroying that root detaches only the droplet.
resource "digitalocean_project" "app" {
  name        = var.project_name
  description = "Resources for ${var.project_name} (managed by push-button-deploy)"
  purpose     = "Web Application"
  environment = "Production"
}

# Assignments are managed via digitalocean_project_resources — never via the
# project's inline `resources` attribute — so infra-app can attach the droplet
# from its own state without the two fighting over the full list.
resource "digitalocean_project_resources" "persistent" {
  project = digitalocean_project.app.id
  resources = compact([
    digitalocean_reserved_ip.this.urn,
    try(digitalocean_database_cluster.pg[0].urn, ""),
    # The state/backup bucket is created by infra-state (local state, so its
    # URN can't be read via remote state) — but Spaces URNs are deterministic.
    var.state_bucket_name == "" ? "" : "do:space:${var.state_bucket_name}",
  ])
}
