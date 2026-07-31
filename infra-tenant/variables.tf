variable "project_name" {
  description = "Short name for this tenant app. Names its Litestream prefix and its state key; must differ from every other app on the same droplet."
  type        = string
}

variable "state_bucket" {
  description = "Spaces bucket holding the HOST app's Terraform state. A tenant shares the host's bucket — that is how it finds the droplet."
  type        = string
}

variable "state_endpoint" {
  description = "S3-compatible Spaces endpoint, e.g. https://nyc3.digitaloceanspaces.com."
  type        = string
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
}

variable "dns_ttl" {
  description = "TTL (seconds) for the A record."
  type        = number
  default     = 300
}
