terraform {
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

locals {
  is_vultr = var.cloud == "vultr"
  is_aws   = var.cloud == "aws"

  # Per-cloud defaults for the generic region/plan variables.
  region = coalesce(var.region, local.is_aws ? "eu-central-1" : "ams")
  plan   = coalesce(var.plan, local.is_aws ? "t3.micro" : "vc2-1c-1gb")

  ssh_public_key = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # Vultr images ship the generic archive.ubuntu.com mirror, so point them at a
  # nearby cloud mirror. AWS AMIs already use a regional mirror -- leave those be.
  default_apt_mirror = local.is_vultr ? "http://${local.region}.clouds.archive.ubuntu.com/ubuntu" : ""
  apt_mirror         = var.apt_mirror != null ? var.apt_mirror : local.default_apt_mirror

  # Amazon's link-local Time Sync Service; elsewhere use the distro pool.
  ntp_servers = local.is_aws ? ["169.254.169.123"] : []

  user_data = templatefile("${path.module}/cloud-init.yml", {
    ssh_public_key    = local.ssh_public_key
    hostname          = var.hostname
    apt_mirror        = local.apt_mirror
    ntp_servers       = local.ntp_servers
    ssh_allowed_cidrs = var.ssh_allowed_cidrs
    timezone          = var.timezone
  })
}
