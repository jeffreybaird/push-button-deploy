# App infrastructure: the disposable droplet. Reads persistent outputs read-only.
# Destroying this module must never touch the DB or reserved IP (story 2.3).

# Reads infra-persistent's state from the shared Spaces bucket. Credentials
# come from AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY (the Spaces keypair),
# exported by the bootstrap.
data "terraform_remote_state" "persistent" {
  backend = "s3"
  config = {
    bucket = var.state_bucket
    key    = "infra-persistent/terraform.tfstate"
    region = "us-east-1" # required, ignored by Spaces
    endpoints = {
      s3 = var.state_endpoint
    }

    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_s3_checksum            = true
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

# Put the droplet in the app's DO project (created in infra-persistent).
# Managed here, in this root's own state, so destroying infra-app detaches only
# the droplet and leaves the persistent resources' assignments alone. try()
# tolerates a persistent state written before projects existed — the droplet
# then stays in the account default project until infra-persistent is re-applied.
locals {
  project_id = try(data.terraform_remote_state.persistent.outputs.project_id, "")
}

resource "digitalocean_project_resources" "app" {
  count = local.project_id == "" ? 0 : 1

  project   = local.project_id
  resources = [digitalocean_droplet.app.urn]
}

# Bind the persistent reserved IP to this droplet. The assignment lives here so a
# destroy releases the binding without destroying the IP itself (it has
# prevent_destroy in infra-persistent).
resource "digitalocean_reserved_ip_assignment" "app" {
  ip_address = local.reserved_ip
  droplet_id = digitalocean_droplet.app.id
}
