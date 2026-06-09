variable "do_token" {
  description = "DigitalOcean API token with write access."
  type        = string
  sensitive   = true
}

variable "spaces_access_id" {
  description = "Spaces access key ID (Spaces uses its own keypair, not the API token)."
  type        = string
  sensitive   = true
}

variable "spaces_secret_key" {
  description = "Spaces secret access key."
  type        = string
  sensitive   = true
}

variable "bucket_name" {
  description = "Spaces bucket for Terraform state. Names are globally unique per region — pick something collision-proof."
  type        = string
}

variable "region" {
  description = "Spaces region slug (must offer Spaces, e.g. nyc3, sfo3, ams3, fra1, sgp1, syd1, blr1)."
  type        = string
  default     = "nyc3"
}
