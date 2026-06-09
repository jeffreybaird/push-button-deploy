variable "do_token" {
  description = "DigitalOcean API token with write access."
  type        = string
  sensitive   = true
}

variable "state_bucket" {
  description = "Spaces bucket holding both roots' Terraform state."
  type        = string
}

variable "state_endpoint" {
  description = "S3-compatible Spaces endpoint, e.g. https://nyc3.digitaloceanspaces.com."
  type        = string
}

variable "ssh_key_name" {
  description = "Name of an SSH key already uploaded to the DO account. Its public key is installed on the droplet for root access (deploy over SSH)."
  type        = string
}

variable "droplet_size" {
  description = "Droplet size slug."
  type        = string
  default     = "s-1vcpu-1gb"
}

variable "droplet_image" {
  description = "Droplet base image slug."
  type        = string
  default     = "ubuntu-24-04-x64"
}

variable "ssh_cidrs" {
  description = "CIDR blocks allowed to reach SSH (port 22). Restrict to your own IP/range."
  type        = list(string)
}
