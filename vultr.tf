provider "vultr" {
  api_key = var.vultr_api_key
}

resource "vultr_ssh_key" "weft" {
  count   = local.is_vultr ? 1 : 0
  name    = var.hostname
  ssh_key = local.ssh_public_key
}

resource "vultr_instance" "server" {
  count       = local.is_vultr && !var.bare_metal ? 1 : 0
  region      = local.region
  plan        = local.plan
  os_id       = 2284 # Ubuntu 24.04 LTS
  hostname    = var.hostname
  label       = var.hostname
  ssh_key_ids = [vultr_ssh_key.weft[0].id]

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
