variable "do_token" {
  description = "DigitalOcean API token with write access."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Short name used to label and name Gitea's own resources. Not the same namespace as an app's PROJECT_NAME — this is the Gitea HOST's own name, fixed for the life of the instance."
  type        = string
  default     = "gitea-infra"
}

variable "region" {
  description = "DigitalOcean region slug."
  type        = string
  default     = "nyc3"
}

variable "vpc_ip_range" {
  description = "Private CIDR block for Gitea's VPC. Default null lets DigitalOcean pick a free range."
  type        = string
  default     = null
}

variable "droplet_size" {
  description = <<-EOT
    Droplet size slug. Gitea itself is tiny (server + Caddy + an idle runner
    total ~300-400MB); what actually drives this is the CI work the co-located
    runner does for every app it deploys:
      zola     - download a binary, `zola build`, scp a tarball: s-1vcpu-1gb
      sinatra  - bundle install, rspec, Docker build of a Ruby image: s-1vcpu-2gb
      phoenix  - mix test + a Postgres service container + a multi-stage
                 Elixir release build: s-2vcpu-4gb
    The default suits ZOLA ONLY. A sinatra or phoenix build on 1GB will
    exhaust RAM, and because the runner is co-located with Gitea the OOM
    killer takes the git server down with it (confirmed live). cloud-init
    adds a 2G swapfile, which turns that into a slow build rather than a
    dead box - but swap is a safety net, not a substitute for sizing.

    The default is the small end deliberately: sizing UP is a painless
    CPU/RAM-only resize, sizing DOWN is not (DigitalOcean cannot shrink a
    disk - see resize_disk in main.tf). Start here, bump it BEFORE the first
    build of a heavier framework.
  EOT
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "droplet_image" {
  description = "Droplet base image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_key_name" {
  description = "Name of an SSH key already uploaded to the DO account. Its public key is installed on the droplet for root access (same key bootstrap.sh already requires)."
  type        = string
}

variable "ssh_cidrs" {
  description = "CIDR blocks allowed to reach SSH (port 22) for admin access to the Gitea droplet itself. Restrict to your own IP/range — this is separate from Gitea's own git+ssh port (2222), which is open to the world like any git host's SSH clone port."
  type        = list(string)
}

variable "data_volume_gb" {
  description = "Size (GiB) of the persistent block-storage volume holding Gitea's data directory (SQLite DB + git repos + Actions logs). Sized well above the droplet's own root disk so repo growth doesn't require a droplet resize."
  type        = number
  default     = 40
}

variable "dnsimple_token" {
  description = "DNSimple API token."
  type        = string
  sensitive   = true
}

variable "dnsimple_account" {
  description = "DNSimple account ID."
  type        = string
}

variable "dns_zone" {
  description = "DNSimple zone (apex domain), e.g. example.com. Same zone bootstrap.sh's apps live in."
  type        = string
}

variable "dns_record" {
  description = "Subdomain record within the zone that Gitea is served on, e.g. \"git\" -> git.example.com."
  type        = string
  default     = "git"
}

variable "dns_ttl" {
  description = "TTL (seconds) for the A record."
  type        = number
  default     = 300
}
