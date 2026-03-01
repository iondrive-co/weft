terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
  }
}

provider "vultr" {
  api_key = var.vultr_api_key
}

resource "vultr_ssh_key" "weft" {
  name    = var.hostname
  ssh_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
}

resource "vultr_instance" "server" {
  region    = var.region
  plan      = var.plan
  os_id     = 2284 # Ubuntu 24.04 LTS
  hostname  = var.hostname
  label     = var.hostname
  ssh_key_ids = [vultr_ssh_key.weft.id]

  user_data = templatefile("${path.module}/cloud-init.yml", {
    ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))
  })
}
