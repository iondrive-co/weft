variable "cloud" {
  description = "Which provider to create the server on: vultr or aws."
  type        = string
  default     = "vultr"

  validation {
    condition     = contains(["vultr", "aws"], var.cloud)
    error_message = "cloud must be either \"vultr\" or \"aws\"."
  }
}

variable "region" {
  description = "Region to create the server in. Defaults to ams (Vultr) or eu-central-1 (AWS)."
  type        = string
  default     = null
}

variable "plan" {
  description = "Server size: a Vultr plan id or an AWS instance type. Defaults to vc2-1c-1gb (Vultr) or t3.micro (AWS)."
  type        = string
  default     = null
}

variable "hostname" {
  description = "Hostname, and the name/label given to the server and its keys."
  type        = string
  default     = "weft"
}

variable "ssh_public_key_path" {
  description = "Public key installed for the ops user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "ssh_allowed_cidrs" {
  description = "CIDRs allowed to reach port 22 (UFW on both clouds, plus the security group on AWS)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "timezone" {
  description = "System timezone."
  type        = string
  default     = "Europe/Berlin"
}

variable "apt_mirror" {
  description = "APT mirror to rewrite archive.ubuntu.com to. Empty string leaves the image's mirror alone."
  type        = string
  default     = null
}

# --- Vultr ---

variable "vultr_api_key" {
  description = "Vultr API key. Only needed when cloud = \"vultr\"."
  type        = string
  sensitive   = true
  default     = ""
}

# --- AWS ---

variable "aws_profile" {
  description = "Shared-config profile to authenticate with. Null uses the default AWS credential chain (env vars, default profile, instance role)."
  type        = string
  default     = null
}

variable "aws_architecture" {
  description = "CPU architecture of the Ubuntu AMI: amd64, or arm64 for Graviton (t4g/m7g/c7g...) instance types."
  type        = string
  default     = "amd64"

  validation {
    condition     = contains(["amd64", "arm64"], var.aws_architecture)
    error_message = "aws_architecture must be either \"amd64\" or \"arm64\"."
  }
}

variable "aws_root_volume_gb" {
  description = "Size of the encrypted gp3 root volume."
  type        = number
  default     = 20
}

variable "aws_subnet_id" {
  description = "Subnet to launch into. Null uses the account's default VPC."
  type        = string
  default     = null
}

variable "bare_metal" {
  description = "Vultr only: a dedicated bare-metal server (plan vbm-*) instead of a cloud instance."
  type        = bool
  default     = false
}
