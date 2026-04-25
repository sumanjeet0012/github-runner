terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────
# Data sources – latest AMIs
# ─────────────────────────────────────────

# Latest Ubuntu 22.04 LTS (Jammy) AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Latest Windows Server 2022 Base AMI
data "aws_ami" "windows" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Windows_Server-2022-English-Full-Base-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ─────────────────────────────────────────
# Security Group
# ─────────────────────────────────────────

resource "aws_security_group" "instances" {
  name        = "${var.project_name}-sg"
  description = "Security group for Ubuntu and Windows instances"
  vpc_id      = var.vpc_id

  # SSH – Ubuntu
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # RDP – Windows
  ingress {
    description = "RDP"
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # WinRM – Windows (optional remote management)
  ingress {
    description = "WinRM"
    from_port   = 5985
    to_port     = 5986
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-sg"
  })
}

# ─────────────────────────────────────────
# Ubuntu Instances
# ─────────────────────────────────────────

resource "aws_instance" "ubuntu" {
  count = var.ubuntu_instance_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.ubuntu_instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instances.id]

  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ubuntu_root_volume_size
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    apt-get update -y
    apt-get upgrade -y
  EOF

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-ubuntu-${count.index + 1}"
    OS   = "Ubuntu"
  })
}

# ─────────────────────────────────────────
# Windows Instances
# ─────────────────────────────────────────

resource "aws_instance" "windows" {
  count = var.windows_instance_count

  ami                    = data.aws_ami.windows.id
  instance_type          = var.windows_instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instances.id]

  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.windows_root_volume_size
    delete_on_termination = true
    encrypted             = true
  }

  # Enable password decryption via key pair
  get_password_data = var.key_name != null ? true : false

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-windows-${count.index + 1}"
    OS   = "Windows"
  })
}
