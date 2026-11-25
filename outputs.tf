locals {
  # A reserved IP is the server's main address once attached; prefer it so the output never names a passing one.
  static_ip = one(concat(vultr_reserved_ip.static[*].subnet, aws_eip.static[*].public_ip))

  # Exactly one of these lists holds a server, so `one` picks it out.
  instance_ip = one(concat(
    vultr_instance.server[*].main_ip,
    vultr_bare_metal_server.server[*].main_ip,
    aws_instance.server[*].public_ip,
  ))
  server_ip = local.instance_ip == null ? null : coalesce(local.static_ip, local.instance_ip)
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

output "static_ip" {
  description = "The reserved IPv4 (Vultr static_ip), or null. This is the address to put in API keys' allowlists."
  value       = local.static_ip
}

output "tunnel" {
  description = "Where tunnel clients connect, or null when the server is not a tunnel egress."
  value = var.tunnel ? {
    endpoint       = local.server_ip == null ? null : "${local.server_ip}:${var.tunnel_port}"
    port           = var.tunnel_port
    cidr           = var.tunnel_cidr
    server_address = cidrhost(var.tunnel_cidr, 1)
  } : null
}
