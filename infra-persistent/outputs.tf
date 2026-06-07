output "reserved_ip" {
  description = "Stable public IP that survives droplet recreation. Assigned to the droplet in infra-app."
  value       = digitalocean_reserved_ip.this.ip_address
}

output "vpc_id" {
  description = "VPC ID consumed by infra-app via terraform_remote_state."
  value       = digitalocean_vpc.this.id
}
