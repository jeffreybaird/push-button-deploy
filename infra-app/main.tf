# App infrastructure: the disposable droplet. Reads persistent outputs read-only.
# Destroying this module must never touch the DB or reserved IP (story 2.3).

data "terraform_remote_state" "persistent" {
  backend = "local"
  config = {
    path = var.persistent_state_path
  }
}

locals {
  project_name = data.terraform_remote_state.persistent.outputs.project_name
  region       = data.terraform_remote_state.persistent.outputs.region
  vpc_id       = data.terraform_remote_state.persistent.outputs.vpc_id
  reserved_ip  = data.terraform_remote_state.persistent.outputs.reserved_ip
  trusted_tag  = data.terraform_remote_state.persistent.outputs.db_trusted_tag
}

# Public key for root SSH access, already uploaded to the DO account.
data "digitalocean_ssh_key" "deploy" {
  name = var.ssh_key_name
}

# The tag must already exist (created in infra-persistent and trusted by the DB
# firewall). Reference it by name rather than recreating it, so the droplet wears
# the EXACT tag the firewall trusts.
data "digitalocean_tag" "app" {
  name = local.trusted_tag
}

resource "digitalocean_droplet" "app" {
  name      = "${local.project_name}-app"
  region    = local.region
  size      = var.droplet_size
  image     = var.droplet_image
  vpc_uuid  = local.vpc_id
  tags      = [data.digitalocean_tag.app.name]
  ssh_keys  = [data.digitalocean_ssh_key.deploy.fingerprint]
  user_data = file("${path.module}/cloud-init.yaml")
}

# Bind the persistent reserved IP to this droplet. The assignment lives here so a
# destroy releases the binding without destroying the IP itself (it has
# prevent_destroy in infra-persistent).
resource "digitalocean_reserved_ip_assignment" "app" {
  ip_address = local.reserved_ip
  droplet_id = digitalocean_droplet.app.id
}
