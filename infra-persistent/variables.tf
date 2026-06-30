variable "do_token" {
  description = "DigitalOcean API token with write access."
  type        = string
  sensitive   = true
}

variable "project_name" {
  description = "Short, app-agnostic name used to label and name persistent resources (e.g. the GitHub repo or app slug)."
  type        = string
}

variable "region" {
  description = "DigitalOcean region slug for all persistent resources."
  type        = string
  default     = "nyc3"
}

variable "vpc_ip_range" {
  description = "Private CIDR block for the VPC. Default null lets DigitalOcean pick a free range — a fixed default collides with any other project's VPC in the account."
  type        = string
  default     = null
}

variable "database_backend" {
  description = "Which database the app uses: 'postgres' provisions a managed Postgres cluster here; 'sqlite' provisions no DB at all (the app keeps a SQLite file on the droplet's local disk, replicated to Spaces by Litestream — see deploy/compose.sqlite.yaml)."
  type        = string
  default     = "postgres"

  validation {
    condition     = contains(["postgres", "sqlite"], var.database_backend)
    error_message = "database_backend must be 'postgres' or 'sqlite'."
  }
}

variable "pg_version" {
  description = "Managed PostgreSQL major version."
  type        = string
  default     = "17"
}

variable "db_size" {
  description = "Managed Postgres node size slug."
  type        = string
  default     = "db-s-1vcpu-1gb"
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
  description = "DNSimple zone (apex domain), e.g. example.com."
  type        = string
}

variable "dns_record" {
  description = "Subdomain record within the zone. Empty string or \"@\" for the apex."
  type        = string
  default     = "app"
}

variable "dns_ttl" {
  description = "TTL (seconds) for the A record."
  type        = number
  default     = 300
}
