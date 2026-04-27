packer {
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = "~> 1"
    }
  }
}

# ─────────────────────────────────────────────────────────────
# Variables
# ─────────────────────────────────────────────────────────────

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}

variable "instance_type" {
  type    = string
  default = "t3.xlarge" # 4 vCPU / 16 GB – comfortable for Docker builds
}

variable "ami_name_prefix" {
  type    = string
  default = "github-runner-linux"
}

variable "go_version" {
  type    = string
  default = "1.22.4"
}

variable "node_version" {
  type    = string
  default = "22"
}

variable "rust_toolchain" {
  type    = string
  default = "stable"
}

# ─────────────────────────────────────────────────────────────
# Source: latest Ubuntu 22.04 LTS (Jammy) x86_64
# ─────────────────────────────────────────────────────────────

source "amazon-ebs" "ubuntu_linux" {
  region        = var.aws_region
  instance_type = var.instance_type

  # Use latest Ubuntu 22.04 LTS from Canonical
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }

  ssh_username = "ubuntu"

  ami_name        = "${var.ami_name_prefix}-{{timestamp}}"
  ami_description = "Pre-baked GitHub Actions self-hosted runner for py-libp2p and test-plans workflows (Linux x64)"

  # Root volume: 50 GB – Docker images + build caches can grow large
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 50
    volume_type           = "gp3"
    delete_on_termination = true
  }

  tags = {
    Name       = "${var.ami_name_prefix}-{{timestamp}}"
    ManagedBy  = "packer"
    Purpose    = "github-runner"
    Workflows  = "py-libp2p,test-plans"
    BaseOS     = "ubuntu-22.04"
    BuildDate  = "{{isotime}}"
  }
}

# ─────────────────────────────────────────────────────────────
# Build
# ─────────────────────────────────────────────────────────────

build {
  name    = "github-runner-linux"
  sources = ["source.amazon-ebs.ubuntu_linux"]

  # Upload the provisioning script
  provisioner "file" {
    source      = "provision.sh"
    destination = "/tmp/provision.sh"
  }

  # Run it as root
  provisioner "shell" {
    inline = [
      "chmod +x /tmp/provision.sh",
      "sudo GO_VERSION=${var.go_version} NODE_VERSION=${var.node_version} RUST_TOOLCHAIN=${var.rust_toolchain} /tmp/provision.sh",
    ]
  }

  # Verify key tools are present
  provisioner "shell" {
    inline = [
      "echo '=== Smoke-testing installed tools ==='",
      "git --version",
      "curl --version | head -1",
      "jq --version",
      "docker --version",
      "docker buildx version",
      "docker compose version",
      "go version",
      "node --version",
      "npm --version",
      "python3 --version",
      "uv --version",
      "RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo rustc --version",
      "RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo cargo --version",
      "nim --version | head -1 || /usr/local/bin/nim --version | head -1",
      "terraform --version | head -1",
      "aws --version",
      "cmake --version | head -1",
      "make --version | head -1",
      # Runner binary
      "test -f /actions-runner/run.sh       && echo '✅ run.sh present'       || (echo '❌ run.sh missing';       exit 1)",
      "test -f /actions-runner/config.sh    && echo '✅ config.sh present'    || (echo '❌ config.sh missing';    exit 1)",
      "test -x /usr/local/bin/github-runner-entrypoint.sh && echo '✅ entrypoint present' || (echo '❌ entrypoint missing'; exit 1)",
      "test -x /usr/local/bin/github-runner-wrapper.sh    && echo '✅ wrapper present'    || (echo '❌ wrapper missing';    exit 1)",
      "test -f /etc/systemd/system/github-runner.service  && echo '✅ systemd unit present' || (echo '❌ systemd unit missing'; exit 1)",
      "test -f /etc/github-runner.env                     && echo '✅ env file present'     || (echo '❌ env file missing';     exit 1)",
      "id actions-runner && echo '✅ actions-runner user present' || (echo '❌ actions-runner user missing'; exit 1)",
      "echo '=== All checks passed ==='",
    ]
  }
}
