# ─────────────────────────────────────────
# Networking data sources
# These reference the existing AWS default VPC and subnet.
# In production you can replace these with your own VPC/subnet
# by changing the filters or setting var.vpc_id / var.subnet_id.
# ─────────────────────────────────────────

# Look up the VPC by ID (supplied via terraform.tfvars)
data "aws_vpc" "main" {
  id = var.vpc_id
}

# Look up the subnet by ID (supplied via terraform.tfvars)
data "aws_subnet" "main" {
  id = var.subnet_id
}

# Look up the internet gateway attached to the VPC
# (needed to verify outbound internet access exists for runners)
data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [var.vpc_id]
  }
}

# ─────────────────────────────────────────
# EC2 Key Pair
# The .pem private key file must exist locally at the path
# specified by var.key_pair_public_key_path BEFORE running
# terraform apply.
#
# Generate with:
#   ssh-keygen -t rsa -b 4096 -f ~/.ssh/libp2p-runner -N ""
# ─────────────────────────────────────────

resource "aws_key_pair" "runner" {
  count      = var.key_name != null && var.key_pair_public_key_path != null ? 1 : 0
  key_name   = var.key_name
  public_key = file(var.key_pair_public_key_path)

  tags = merge(var.common_tags, {
    Name = var.key_name
  })

  lifecycle {
    # Never destroy an existing key pair — the .pem file cannot be recovered
    prevent_destroy = true
  }
}

# ─────────────────────────────────────────
# GitHub Webhook (documented, not automated)
# ─────────────────────────────────────────
# The GitHub org webhook CANNOT be managed by Terraform because
# the GitHub provider requires a GitHub App or OAuth token.
# It must be registered manually once after the first apply:
#
#   URL:          (see output: webhook_url)
#   Content type: application/json
#   Secret:       var.github_webhook_secret
#   Events:       Workflow jobs only
#
# Org webhook settings:
#   https://github.com/organizations/py-libp2p-runners/settings/hooks
