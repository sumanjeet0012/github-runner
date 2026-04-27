# GitHub Runner AMI – Linux (Packer)

Pre-baked AMI for self-hosted GitHub Actions runners.  
Covers everything needed by **py-libp2p** and **test-plans** workflows without installing tools at runtime.

---

## What's pre-installed

| Category | Tool / Package | Why it's needed |
|---|---|---|
| **System** | `build-essential`, `make`, `cmake`, `pkg-config` | C/C++ compilation, Shadow simulator, Rust crates |
| **System** | `libgmp-dev` | Cryptographic libraries (py-libp2p) |
| **System** | `libclang-dev`, `libc-dbg` | Shadow simulator build deps |
| **System** | `libglib2.0-0`, `libglib2.0-dev` | Shadow simulator runtime |
| **System** | `python3-networkx`, `netbase`, `findutils`, `xz-utils` | Shadow simulator |
| **System** | `curl`, `wget`, `git`, `jq`, `unzip` | Workflow utilities |
| **Docker** | Docker CE + `docker-buildx-plugin` + `docker-compose-plugin` | Container builds (transport-interop, hole-punch, perf) |
| **Docker** | `/etc/buildkit/buildkitd.toml` | docker.io mirror → avoids rate limits on self-hosted runners |
| **Go** | `go` (configurable, default 1.22.4) | gossipsub-interop, transport-interop Go implementations, `add-new-impl-versions` |
| **Node.js** | `node` + `npm` (default v22) | transport-interop runner, hole-punch runner, `npm ci` steps |
| **Python** | `uv` (system-wide) + Python 3.10–3.13 | py-libp2p tox matrix |
| **Python** | `tox` (via `uv tool install`) | py-libp2p CI |
| **Rust** | `rustup` + `cargo` + `rustc` (stable) | gossipsub-interop Rust implementation |
| **Nim** | `choosenim` + `nim` + `nimble` (stable) | py-libp2p interop tests (`nim-libp2p`) |
| **Terraform** | `terraform` (latest 1.x) | perf benchmark infrastructure |
| **AWS** | `aws` CLI v2 | Secrets Manager, EC2 tags, SSM |
| **Runner** | GitHub Actions runner binary | Self-hosted runner bootstrap |

---

## Directory layout

```
packer/
├── github-runner.pkr.hcl   # Packer template
└── provision.sh             # Provisioning script (runs as root inside the AMI)
```

---

## Prerequisites

1. [Install Packer](https://developer.hashicorp.com/packer/install) ≥ 1.10  
2. AWS credentials with permission to:
   - `ec2:RunInstances`, `ec2:DescribeInstances`, `ec2:TerminateInstances`
   - `ec2:CreateImage`, `ec2:DeregisterImage`, `ec2:DescribeImages`
   - `iam:PassRole` (if using an instance profile)

---

## Build

```bash
cd packer

# Initialise Packer plugins (first time only)
packer init github-runner.pkr.hcl

# Validate
packer validate github-runner.pkr.hcl

# Build (uses defaults)
packer build github-runner.pkr.hcl

# Build with custom versions
packer build \
  -var "go_version=1.22.4" \
  -var "node_version=22" \
  -var "rust_toolchain=stable" \
  -var "aws_region=eu-north-1" \
  github-runner.pkr.hcl
```

The resulting AMI ID is printed at the end and tagged with `Purpose=github-runner`.

---

## Using the AMI in Terraform

Once built, update `terraform.tfvars` (or the `aws_ami` data source in `main.tf`) to use the new AMI ID instead of the vanilla Ubuntu base:

```hcl
# terraform.tfvars
linux_ami_id = "ami-0xxxxxxxxxxxxxxxxx"  # output from packer build
```

Or filter by tag in `main.tf`:

```hcl
data "aws_ami" "runner" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "tag:Purpose"
    values = ["github-runner"]
  }

  filter {
    name   = "name"
    values = ["github-runner-linux-*"]
  }
}
```

---

## Customising versions

| Variable | Default | Description |
|---|---|---|
| `go_version` | `1.22.4` | Go release (see https://go.dev/dl/) |
| `node_version` | `22` | Node.js major version |
| `rust_toolchain` | `stable` | Rust toolchain (`stable` / `nightly` / `1.78.0`) |
| `aws_region` | `eu-north-1` | Region where the AMI is built |
| `instance_type` | `t3.xlarge` | Builder instance (needs ~16 GB RAM for Rust/Go builds) |

---

## Notes

- **Nim** is installed into `/usr/local/choosenim` and symlinked into `/usr/local/bin`.  
  The py-libp2p `tox.yml` workflow also downloads choosenim at runtime and appends `~/.nimble/bin` to `$PATH` — the pre-installed version acts as a fast fallback.
- **Shadow simulator** is built from source at CI time (`gossipsub-interop-pr.yml`), but all compile-time dependencies (`cmake`, `libclang-dev`, `libglib2.0-dev`, etc.) are pre-installed so the build is fast.
- **Docker Compose v2** is installed as a CLI plugin (`docker compose`), matching what the hole-punch interop action installs at runtime (`docker-compose-linux-x86_64`).
- The `/etc/buildkit/buildkitd.toml` file is detected by the transport-interop and hole-punch actions to enable the docker.io mirror automatically.
