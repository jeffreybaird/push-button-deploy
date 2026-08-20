# Gitea's own infrastructure: a single droplet running Gitea + its Actions
# runner (co-located — see README "Gitea support"). Unlike the app roots this
# is ONE combined root, not a persistent/app split: there's exactly one
# Gitea instance, applied once, not one per project.
#
# Still protects its two genuinely stateful resources — the reserved IP and
# the data volume (SQLite DB + git repos + Actions logs) — with
# prevent_destroy, the same guard infra-persistent uses. Recreating the
# droplet (e.g. a resize) re-attaches the same volume at the same IP and
# loses nothing; destroying the volume/IP themselves takes a deliberate,
# guard-lifted `terraform destroy` (see teardown-gitea.sh).

resource "digitalocean_vpc" "gitea" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_ip_range
}

resource "digitalocean_reserved_ip" "gitea" {
  region = var.region

  lifecycle {
    prevent_destroy = true
  }
}

# Gitea's data directory (SQLite DB, git repo objects, Actions logs, LFS
# objects) lives here, not on the droplet's root disk — a droplet recreation
# (resize, image change, cloud-init fix) re-attaches this and loses nothing.
# This is NOT itself backed up/replicated (unlike an app's SQLite file, which
# Litestream streams continuously) — a multi-file git repo store doesn't fit
# that single-file replication model. Snapshot this volume yourself for a real
# backup story; see README "Gitea support" for the tradeoff this accepts.
resource "digitalocean_volume" "gitea_data" {
  name                    = "${var.project_name}-data"
  region                  = var.region
  size                    = var.data_volume_gb
  initial_filesystem_type = "ext4"

  lifecycle {
    prevent_destroy = true
  }
}

data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

resource "digitalocean_droplet" "gitea" {
  name       = "${var.project_name}-host"
  region     = var.region
  size       = var.droplet_size
  image      = var.droplet_image
  vpc_uuid   = digitalocean_vpc.gitea.id
  ssh_keys   = [data.digitalocean_ssh_key.deploy.fingerprint]
  volume_ids = [digitalocean_volume.gitea_data.id]
  user_data  = file("${path.module}/cloud-init.yaml")

  # Resize CPU/RAM only, never the disk. DigitalOcean can grow a disk but
  # never shrink one, so a disk-inclusive resize is a ONE-WAY door: bump the
  # size once and you can never come back down without replacing the droplet.
  # Everything worth keeping lives on the attached volume rather than the root
  # disk, so giving up disk resizing costs nothing and keeps droplet_size a
  # freely adjustable dial in both directions.
  resize_disk = false
}

resource "digitalocean_reserved_ip_assignment" "gitea" {
  ip_address = digitalocean_reserved_ip.gitea.ip_address
  droplet_id = digitalocean_droplet.gitea.id
}
