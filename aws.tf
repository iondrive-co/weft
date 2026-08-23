provider "aws" {
  # Terraform configures every provider in the config, even one whose resources
  # are all counted out. So when cloud != "aws" this is handed a valid region
  # and placeholder credentials, purely to keep configuration from failing on a
  # machine that has no AWS setup at all. Nothing here is ever used to make a
  # request: every aws resource and data source below is count = 0.
  region  = local.is_aws ? local.region : "eu-central-1"
  profile = local.is_aws ? var.aws_profile : null

  access_key                  = local.is_aws ? null : "weft-unused"
  secret_key                  = local.is_aws ? null : "weft-unused"
  skip_credentials_validation = !local.is_aws
  skip_requesting_account_id  = !local.is_aws

  default_tags {
    tags = {
      ManagedBy = "weft"
      Name      = var.hostname
    }
  }
}

# Canonical's official Ubuntu 24.04 (Noble) AMI, newest build in the region.
data "aws_ami" "ubuntu" {
  count       = local.is_aws ? 1 : 0
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-${var.aws_architecture}-server-*"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Network. With no aws_subnet_id given, launch into the account's default VPC --
# its per-AZ default subnets are public, which is what a single box needs.
data "aws_vpc" "default" {
  count   = local.is_aws && var.aws_subnet_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = local.is_aws && var.aws_subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default[0].id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "selected" {
  count = local.is_aws && var.aws_subnet_id != null ? 1 : 0
  id    = var.aws_subnet_id
}

locals {
  # Pick the lowest subnet id rather than letting EC2 choose, so repeated
  # applies keep landing in the same availability zone.
  aws_subnet_id = local.is_aws ? (
    var.aws_subnet_id != null
    ? var.aws_subnet_id
    : sort(data.aws_subnets.default[0].ids)[0]
  ) : null

  aws_vpc_id = local.is_aws ? (
    var.aws_subnet_id != null
    ? data.aws_subnet.selected[0].vpc_id
    : data.aws_vpc.default[0].id
  ) : null
}

resource "aws_key_pair" "weft" {
  count      = local.is_aws ? 1 : 0
  key_name   = var.hostname
  public_key = local.ssh_public_key
}

resource "aws_security_group" "weft" {
  count       = local.is_aws ? 1 : 0
  name_prefix = "${var.hostname}-"
  description = "weft: SSH in, everything out"
  vpc_id      = local.aws_vpc_id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_allowed_cidrs
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "server" {
  count                       = local.is_aws ? 1 : 0
  ami                         = data.aws_ami.ubuntu[0].id
  instance_type               = local.plan
  key_name                    = aws_key_pair.weft[0].key_name
  vpc_security_group_ids      = [aws_security_group.weft[0].id]
  subnet_id                   = local.aws_subnet_id
  associate_public_ip_address = true

  user_data                   = local.user_data
  user_data_replace_on_change = true

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.aws_root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  # Require IMDSv2 (token-based instance metadata).
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
}
