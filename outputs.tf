locals {
  # Exactly one of these lists holds a server, so `one` picks it out.
  server_ip = one(concat(
    vultr_instance.server[*].main_ip,
    aws_instance.server[*].public_ip,
  ))
}

output "server_ip" {
  description = "Public IP of the server."
  value       = local.server_ip
}

output "server_cloud" {
  description = "Cloud the server lives on."
  value       = var.cloud
}

output "server_region" {
  description = "Region the server lives in."
  value       = local.region
}

output "ssh_command" {
  description = "Command to connect."
  value       = local.server_ip == null ? null : "ssh ops@${local.server_ip}"
}
