output "bucket" {
  description = "State bucket name — goes into backend.hcl for both roots."
  value       = digitalocean_spaces_bucket.tfstate.name
}

output "endpoint" {
  description = "S3-compatible endpoint for the bucket's region."
  value       = "https://${digitalocean_spaces_bucket.tfstate.region}.digitaloceanspaces.com"
}
