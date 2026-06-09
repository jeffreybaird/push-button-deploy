# Managed Postgres: single-node, in the VPC, reachable only by tag-trusted hosts.
# Data lifecycle is decoupled from compute — prevent_destroy guards the cluster.

# The tag the app droplet wears (applied in infra-app, story 2.1). The DB firewall
# trusts THIS tag, not a droplet ID, so a recreated droplet keeps DB access as long
# as it wears the tag. Output below so infra-app reads the exact same string.
resource "digitalocean_tag" "app" {
  name = "${var.project_name}-app"
}

resource "digitalocean_database_cluster" "pg" {
  name                 = "${var.project_name}-pg"
  engine               = "pg"
  version              = var.pg_version
  size                 = var.db_size
  region               = var.region
  node_count           = 1
  private_network_uuid = digitalocean_vpc.this.id

  lifecycle {
    prevent_destroy = true
  }
}

# App-specific database + user (not the shared doadmin/defaultdb).
resource "digitalocean_database_db" "app" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = var.project_name
}

resource "digitalocean_database_user" "app" {
  cluster_id = digitalocean_database_cluster.pg.id
  name       = var.project_name
}

# Cluster CA certificate — delivered to the droplet at deploy time so the app
# can verify the server cert (verify_peer, story 7.3).
data "digitalocean_database_ca" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id
}

# Private-only access: the sole trusted source is the app tag. No public CIDRs,
# no droplet IDs.
resource "digitalocean_database_firewall" "pg" {
  cluster_id = digitalocean_database_cluster.pg.id

  rule {
    type  = "tag"
    value = digitalocean_tag.app.name
  }
}
