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
# IAM Role – lets Ubuntu instances read the PAT secret
# ─────────────────────────────────────────

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = "${var.project_name}-runner-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-runner-role"
  })
}

data "aws_iam_policy_document" "read_pat_secret" {
  statement {
    sid    = "ReadGitHubPAT"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [aws_secretsmanager_secret.github_pat.arn]
  }
}

resource "aws_iam_role_policy" "read_pat_secret" {
  name   = "read-github-pat"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.read_pat_secret.json
}

resource "aws_iam_instance_profile" "runner" {
  name = "${var.project_name}-runner-profile"
  role = aws_iam_role.runner.name
}

# ─────────────────────────────────────────
# GitHub PAT – AWS Secrets Manager
# ─────────────────────────────────────────

# If the secret already exists and is pending deletion (e.g. after a previous
# terraform destroy), restore it first so the resource block below can take
# ownership and overwrite the value. The || true means this is a no-op when
# the secret is not in a pending-deletion state.
resource "terraform_data" "restore_github_pat_secret" {
  triggers_replace = [var.github_pat_secret_name]

  provisioner "local-exec" {
    command = <<-CMD
      aws secretsmanager restore-secret \
        --region ${var.aws_region} \
        --secret-id '${var.github_pat_secret_name}' 2>/dev/null || true
    CMD
  }
}

resource "aws_secretsmanager_secret" "github_pat" {
  name                    = var.github_pat_secret_name
  description             = "GitHub Personal Access Token for ${var.project_name}"
  recovery_window_in_days = 0 # Force-delete on destroy so the name can be reused immediately

  tags = merge(var.common_tags, {
    Name = var.github_pat_secret_name
  })

  depends_on = [terraform_data.restore_github_pat_secret]
}

resource "aws_secretsmanager_secret_version" "github_pat" {
  secret_id     = aws_secretsmanager_secret.github_pat.id
  secret_string = var.github_pat
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

locals {
  # Build the environment variables the entrypoint.sh expects
  runner_env = {
    RUNNER_SCOPE = var.github_runner_scope
    REPO_URL     = var.github_runner_scope == "repo" ? var.github_repo_url : ""
    ORG_NAME     = var.github_runner_scope == "org" ? var.github_org_name : ""
    LABELS       = var.github_runner_labels
  }
}

resource "aws_instance" "ubuntu" {
  count = var.ubuntu_instance_count

  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.ubuntu_instance_type
  key_name               = var.key_name
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instances.id]
  iam_instance_profile   = aws_iam_instance_profile.runner.name

  associate_public_ip_address = var.associate_public_ip

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.ubuntu_root_volume_size
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tpl", {
    aws_region             = var.aws_region
    github_pat_secret_name = var.github_pat_secret_name
    runner_scope           = var.github_runner_scope
    repo_url               = var.github_runner_scope == "repo" ? var.github_repo_url : ""
    org_name               = var.github_runner_scope == "org" ? var.github_org_name : ""
    runner_labels          = var.github_runner_labels
    runner_name            = "${var.github_runner_name_prefix}-${count.index + 1}"
    entrypoint_script      = file("${path.module}/entrypoint.sh")
  })

  user_data_replace_on_change = true

  tags = merge(var.common_tags, {
    Name = "${var.project_name}-ubuntu-${count.index + 1}"
    OS   = "Ubuntu"
    Role = "github-runner"
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
