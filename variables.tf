# ─────────────────────────────────────────
# General
# ─────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
  default     = "my-project"
}

variable "common_tags" {
  description = "Tags applied to every resource"
  type        = map(string)
  default = {
    Project     = "my-project"
    ManagedBy   = "Terraform"
  }
}

# ─────────────────────────────────────────
# Networking
# ─────────────────────────────────────────

variable "vpc_id" {
  description = "VPC ID where instances will be launched"
  type        = string
}

variable "subnet_id" {
  description = "Subnet ID where instances will be launched"
  type        = string
}

variable "associate_public_ip" {
  description = "Whether to assign a public IP address to instances"
  type        = bool
  default     = true
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach SSH (22) and RDP (3389)"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production!
}

# ─────────────────────────────────────────
# Key Pair
# ─────────────────────────────────────────

variable "key_name" {
  description = "Name of an existing EC2 Key Pair for SSH / RDP password decryption"
  type        = string
  default     = null
}

# ─────────────────────────────────────────
# GitHub Runner configuration
# ─────────────────────────────────────────

variable "github_runner_scope" {
  description = "Scope of the runner: 'repo' or 'org'"
  type        = string
  default     = "repo"

  validation {
    condition     = contains(["repo", "org"], var.github_runner_scope)
    error_message = "github_runner_scope must be 'repo' or 'org'."
  }
}

variable "github_repo_url" {
  description = "Full URL of the GitHub repo, e.g. https://github.com/owner/repo (used when scope=repo)"
  type        = string
  default     = ""
}

variable "github_org_name" {
  description = "GitHub organisation name (used when scope=org)"
  type        = string
  default     = ""
}

variable "github_runner_labels" {
  description = "Comma-separated list of extra labels to apply to each runner, e.g. 'self-hosted,linux,x64'"
  type        = string
  default     = "self-hosted,linux,x64"
}

variable "github_runner_name_prefix" {
  description = "Prefix for the runner name. Instance index is appended automatically."
  type        = string
  default     = "ec2-runner"
}

variable "github_webhook_secret" {
  description = "Secret used to verify GitHub webhook payloads (set the same value in GitHub org webhook settings)"
  type        = string
  sensitive   = true
  default     = ""
}

# ─────────────────────────────────────────
# GitHub PAT – AWS Secrets Manager
# ─────────────────────────────────────────

variable "github_pat_secret_name" {
  description = "Name for the AWS Secrets Manager secret that will store the GitHub PAT"
  type        = string
  default     = "github-pat"
}

variable "github_pat" {
  description = "GitHub Personal Access Token to store in AWS Secrets Manager"
  type        = string
  sensitive   = true
}

# ─────────────────────────────────────────
# Ubuntu instances
# ─────────────────────────────────────────

variable "ubuntu_instance_count" {
  description = "Number of Ubuntu instances to create (set to 0 to skip)"
  type        = number
  default     = 1

  validation {
    condition     = var.ubuntu_instance_count >= 0
    error_message = "ubuntu_instance_count must be 0 or a positive integer."
  }
}

variable "ubuntu_instance_type" {
  description = "EC2 instance type for Ubuntu instances"
  type        = string
  default     = "t3.micro"
}

variable "ubuntu_root_volume_size" {
  description = "Root EBS volume size (GiB) for Ubuntu instances"
  type        = number
  default     = 20
}

# ─────────────────────────────────────────
# Windows instances
# ─────────────────────────────────────────

variable "windows_instance_count" {
  description = "Number of Windows instances to create (set to 0 to skip)"
  type        = number
  default     = 1

  validation {
    condition     = var.windows_instance_count >= 0
    error_message = "windows_instance_count must be 0 or a positive integer."
  }
}

variable "windows_instance_type" {
  description = "EC2 instance type for Windows instances (min t3.medium recommended)"
  type        = string
  default     = "t3.medium"
}

variable "windows_root_volume_size" {
  description = "Root EBS volume size (GiB) for Windows instances"
  type        = number
  default     = 50
}
