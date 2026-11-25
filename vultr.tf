provider "vultr" {
  api_key = var.vultr_api_key
}

resource "vultr_ssh_key" "weft" {
  count   = local.is_vultr ? 1 : 0
  name    = var.hostname
  ssh_key = local.ssh_public_key
}

# A reserved IPv4 lives apart from the server: rebuilding the server (`./weft.sh rebuild`) keeps the address, so an
# API key's IP allowlist that names it keeps working. Billed while reserved, attached or not.
resource "vultr_reserved_ip" "static" {
  count   = local.is_vultr && var.static_ip ? 1 : 0
  region  = local.region
  ip_type = "v4"
  label   = "${var.hostname}-static"

  lifecycle {
    precondition {
      condition     = !var.bare_metal
      error_message = "static_ip is for cloud instances; weft does not attach reserved IPs to bare-metal servers."
    }
  }
}

# Vultr's edge firewall, in front of UFW: whatever no rule names is dropped before it reaches the guest.
resource "vultr_firewall_group" "weft" {
  count       = local.is_vultr && var.vultr_firewall ? 1 : 0
  description = var.hostname
}

locals {
  # 0.0.0.0/0 (or nothing listed) means SSH from anywhere, the same as UFW reads it.
  vultr_ssh_cidrs = (length(var.ssh_allowed_cidrs) == 0 || contains(var.ssh_allowed_cidrs, "0.0.0.0/0")
  ? ["0.0.0.0/0"] : var.ssh_allowed_cidrs)
}

resource "vultr_firewall_rule" "ssh" {
  for_each          = local.is_vultr && var.vultr_firewall ? toset(local.vultr_ssh_cidrs) : toset([])
  firewall_group_id = vultr_firewall_group.weft[0].id
  protocol          = "tcp"
  ip_type           = "v4"
  subnet            = split("/", each.value)[0]
  subnet_size       = tonumber(split("/", each.value)[1])
  port              = "22"
  notes             = "ssh"
}

# The tunnel must answer clients whose address changes (a phone link, a CGNAT pool), so its port is open to all.
# WireGuard sends nothing back to a packet that is not signed by a known peer key, so the port does not show as open.
resource "vultr_firewall_rule" "tunnel" {
  count             = local.is_vultr && var.vultr_firewall && var.tunnel ? 1 : 0
  firewall_group_id = vultr_firewall_group.weft[0].id
  protocol          = "udp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  port              = tostring(var.tunnel_port)
  notes             = "wireguard"
}

# ICMP keeps path-MTU discovery working through the tunnel (UFW still answers only what it allows).
resource "vultr_firewall_rule" "icmp" {
  count             = local.is_vultr && var.vultr_firewall ? 1 : 0
  firewall_group_id = vultr_firewall_group.weft[0].id
  protocol          = "icmp"
  ip_type           = "v4"
  subnet            = "0.0.0.0"
  subnet_size       = 0
  notes             = "icmp"
}

resource "vultr_instance" "server" {
  count       = local.is_vultr && !var.bare_metal ? 1 : 0
  region      = local.region
  plan        = local.plan
  os_id       = 2284 # Ubuntu 24.04 LTS
  hostname    = var.hostname
  label       = var.hostname
  ssh_key_ids = [vultr_ssh_key.weft[0].id]

  reserved_ip_id    = var.static_ip ? vultr_reserved_ip.static[0].id : null
  firewall_group_id = var.vultr_firewall ? vultr_firewall_group.weft[0].id : null

  user_data = local.user_data

  # user_data forces replacement: an edit to cloud-init.yml must reach new servers only, never rebuild a running one
  lifecycle {
    ignore_changes = [user_data]
  }
}

# A dedicated (bare-metal) server instead of a cloud instance, when `bare_metal` is set (for workloads that need many
# cores or local NVMe). Billed hourly up to the plan's monthly price; `plan` is a vbm-* id.
# mdisk_mode jbod leaves each disk on its own, so the second NVMe can hold data apart from the OS.
resource "vultr_bare_metal_server" "server" {
  count       = local.is_vultr && var.bare_metal ? 1 : 0
  region      = local.region
  plan        = local.plan
  os_id       = 2284 # Ubuntu 24.04 LTS
  hostname    = var.hostname
  label       = var.hostname
  ssh_key_ids = [vultr_ssh_key.weft[0].id]
  mdisk_mode  = "jbod"

  user_data = local.user_data

  lifecycle {
    ignore_changes = [user_data]
  }
}
