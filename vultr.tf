provider "vultr" {
  api_key = var.vultr_api_key
}

resource "vultr_ssh_key" "weft" {
  count   = local.is_vultr ? 1 : 0
  name    = var.hostname
  ssh_key = local.ssh_public_key
}

resource "vultr_instance" "server" {
  count       = local.is_vultr ? 1 : 0
  region      = local.region
  plan        = local.plan
  os_id       = 2284 # Ubuntu 24.04 LTS
  hostname    = var.hostname
  label       = var.hostname
  ssh_key_ids = [vultr_ssh_key.weft[0].id]

  user_data = local.user_data
}
