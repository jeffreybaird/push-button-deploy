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
  description = "Private CIDR block for the VPC. Must not overlap other VPCs in the account."
  type        = string
  default     = "10.10.10.0/24"
}
