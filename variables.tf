variable "vultr_api_key" {
  type      = string
  sensitive = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "region" {
  type    = string
  default = "ams"
}

variable "plan" {
  type    = string
  default = "vc2-1c-1gb"
}

variable "hostname" {
  type    = string
  default = "weft"
}
