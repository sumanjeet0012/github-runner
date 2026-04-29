# GitHub Actions Ephemeral Runner — Complete Maintainer Guide

> **Audience:** Anyone who needs to maintain, debug, extend, or rebuild this system long-term.  
> **Last updated:** April 2026

---

## Table of Contents

1. [What This System Does (30-second summary)](#1-what-this-system-does)
2. [Repository File Map](#2-repository-file-map)
3. [Architecture Deep Dive](#3-architecture-deep-dive)
4. [Every File Explained](#4-every-file-explained)
5. [What Happens After `terraform apply`](#5-what-happens-after-terraform-apply)
6. [The Full Job Lifecycle (webhook → EC2 → terminate)](#6-the-full-job-lifecycle)
7. [The AMI Build Process (Packer)](#7-the-ami-build-process-packer)
8. [Files That Are NOT Currently Used](#8-files-that-are-not-currently-used)
9. [Key Configuration Values](#9-key-configuration-values)
10. [Day-to-Day Operations](#10-day-to-day-operations)
11. [How to Rebuild the AMI](#11-how-to-rebuild-the-ami)
12. [How to Register a Manual Test Runner](#12-how-to-register-a-manual-test-runner)
13. [Debugging Runbook](#13-debugging-runbook)
14. [Cost Model](#14-cost-model)
15. [Known Gotchas](#15-known-gotchas)

---

## 1. What This System Does

This project runs **ephemeral GitHub Actions self-hosted runners** on AWS EC2 for the `py-libp2p-runners` GitHub organisation.

**Ephemeral** means:
- Every GitHub Actions job gets a **brand-new EC2 instance**
- The instance registers as a runner, runs **exactly one job**, then **self-terminates**
- There are **zero standing instances** when no jobs are running
- Cost is zero when idle

**Why self-hosted?** The libp2p workflows need tools that don't fit on GitHub-hosted runners:
- Nim (for py-libp2p interop tests)
- Multiple Python versions (3.10–3.13) via uv
- Rust MSRV + beta + nightly toolchains
- wasm-pack, cargo-deny, cargo-audit
- Java 11 (Temurin) for jvm-libp2p
- Shadow network simulator compile-time deps
- Docker Buildx with a GCR mirror config

---

## 2. Repository File Map

```
github-runner/
│
├── ── TERRAFORM (Infrastructure) ──────────────────────────────────────────
│
├── main.tf                  ← IAM roles, Secrets Manager, Security Group,
│                              EC2 Launch Templates (Linux + Windows), Ubuntu static instances
├── lambda.tf                ← SQS queues, DynamoDB, Lambda functions, API Gateway,
│                              all IAM for Lambda
├── networking.tf            ← VPC/subnet data sources, EC2 key pair, webhook docs
├── variables.tf             ← All input variable declarations with defaults
├── outputs.tf               ← Useful values printed after apply (webhook URL, etc.)
├── terraform.tfvars         ← YOUR actual values (region, VPC, PAT, AMI ID, etc.)
├── terraform.tfstate        ← Terraform state (tracks what exists in AWS)
├── terraform.tfstate.backup ← Previous state backup (auto-created by Terraform)
├── tfplan                   ← Saved plan file (from terraform plan -out=tfplan)
│
├── ── LAMBDA (Python) ─────────────────────────────────────────────────────
│
├── lambda/
│   ├── index.py             ← Lambda 1: Webhook receiver (GitHub → SQS)
│   ├── processor.py         ← Lambda 2: Job processor (SQS → EC2 launch)
│   └── runner_webhook.zip   ← Auto-generated ZIP (both files, created by Terraform)
│
├── ── EC2 BOOT SCRIPTS ────────────────────────────────────────────────────
│
├── user_data.sh.tpl         ← Linux boot script (Terraform template, runs on EC2 start)
├── user_data.ps1.tpl        ← Windows boot script (Terraform template, runs on EC2 start)
│
├── ── PACKER (AMI Builder) ────────────────────────────────────────────────
│
├── packer/
│   ├── github-runner.pkr.hcl ← Packer build definition (what AMI to build, how)
│   ├── provision.sh          ← The provisioning script (installs ALL tools into AMI)
│   ├── verify-ami.sh         ← Verification script (run on instance to check all tools)
│   └── README.md             ← Packer-specific docs
│
├── ── DOCUMENTATION ───────────────────────────────────────────────────────
│
├── README.md                ← High-level project overview
├── ARCHITECTURE.md          ← Architecture + troubleshooting guide
├── MAINTAINER_GUIDE.md      ← THIS FILE
├── WINDOWS_SETUP.md         ← Windows runner setup notes
│
├── ── UNUSED / LEGACY ─────────────────────────────────────────────────────
│
├── entrypoint.sh            ← ⚠️ NOT USED — old Docker-based entrypoint (pre-AMI era)
├── test-runner.ps1          ← ⚠️ NOT USED — old Windows test script
├── logs.txt                 ← ⚠️ NOT USED — scratch log file from manual testing
│
└── extra/                   ← The libp2p repos (cloned for dependency analysis)
    ├── py-libp2p/           ← Python libp2p implementation
    ├── go-libp2p/           ← Go libp2p implementation
    ├── js-libp2p/           ← JavaScript libp2p implementation
    ├── rust-libp2p/         ← Rust libp2p implementation
    ├── jvm-libp2p/          ← JVM libp2p implementation
    ├── cpp-libp2p/          ← C++ libp2p implementation
    ├── test-plans/          ← Cross-language interop tests
    ├── unified-testing/     ← Unified test runner (self-hosted workflows)
    └── logs.txt             ← ⚠️ NOT USED — scratch log file
```

---

## 3. Architecture Deep Dive

```
┌─────────────────────────────────────────────────────────────────────┐
│                        GitHub                                        │
│  py-libp2p repo pushes/PRs                                           │
│  workflow_job event fires (action: queued)                           │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ HTTPS POST (webhook)
                               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    AWS eu-north-1                                     │
│                                                                      │
│  API Gateway (HTTP API)                                              │
│  POST /webhook                                                       │
│       │                                                              │
│       ▼                                                              │
│  Lambda 1: index.py  (webhook receiver, timeout=10s)                │
│  ├─ Validates HMAC-SHA256 signature                                  │
│  ├─ Checks labels contain "self-hosted" + "linux" or "windows"      │
│  ├─ On action="queued" → sends message to SQS                       │
│  └─ Returns 200 to GitHub immediately                                │
│       │                                                              │
│       ▼                                                              │
│  SQS Queue: libp2p-runner-runner-jobs                                │
│  (visibility timeout=5min, retention=24h)                            │
│       │                                                              │
│       ▼ (event source mapping, automatic)                            │
│  Lambda 2: processor.py  (job processor, timeout=30s)               │
│  ├─ Reads active_count from DynamoDB                                 │
│  ├─ If count < runner_max_pool_size (2):                             │
│  │   ├─ Increments active_count in DynamoDB                         │
│  │   └─ Calls ec2:RunInstances with Launch Template                 │
│  └─ If count >= max: message goes back to SQS (retried in 5min)     │
│       │                                                              │
│       ▼                                                              │
│  EC2 Instance (from AMI built by Packer)                             │
│  ├─ user_data.sh.tpl runs on first boot                              │
│  │   ├─ Fetches GitHub PAT from Secrets Manager                     │
│  │   ├─ Writes /etc/github-runner.env                               │
│  │   └─ Starts github-runner.service (systemd)                      │
│  │                                                                   │
│  ├─ github-runner-wrapper.sh  (systemd ExecStart)                   │
│  │   ├─ Gets INSTANCE_ID + REGION from IMDSv2                       │
│  │   ├─ Reads GitHubJobId tag from EC2                              │
│  │   ├─ Checks if job is still active on GitHub API                 │
│  │   ├─ If cancelled → terminates instance immediately              │
│  │   └─ If active → calls entrypoint.sh                             │
│  │                                                                   │
│  ├─ github-runner-entrypoint.sh                                      │
│  │   ├─ Calls GitHub API to get registration token                  │
│  │   ├─ Runs config.sh (registers runner, --ephemeral)              │
│  │   └─ Runs run.sh (picks up job, executes it)                     │
│  │                                                                   │
│  └─ After job completes:                                             │
│      └─ wrapper.sh calls ec2:TerminateInstances (self-terminate)    │
│                                                                      │
│  DynamoDB: libp2p-runner-runner-pool                                 │
│  └─ Single row {pk:"pool", active_count: N}                         │
│     active_count is decremented by processor.py when job completes  │
│                                                                      │
│  SQS DLQ: libp2p-runner-runner-dlq                                  │
│  └─ Messages land here after 1000 retries (effectively never)       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 4. Every File Explained

### `main.tf`

The core Terraform file. Creates:

| Resource | Purpose |
|---|---|
| `aws_iam_role.runner` | IAM role attached to EC2 runner instances |
| `aws_iam_role_policy.read_pat_secret` | Allows EC2 to read the PAT from Secrets Manager and self-terminate |
| `aws_iam_instance_profile.runner` | Wraps the IAM role so EC2 can use it |
| `terraform_data.restore_github_pat_secret` | Restores secret if it's pending deletion (after destroy) |
| `aws_secretsmanager_secret.github_pat` | The Secrets Manager secret that stores the GitHub PAT |
| `aws_secretsmanager_secret_version.github_pat` | The actual PAT value inside the secret |
| `aws_security_group.instances` | Allows SSH (22), RDP (3389), WinRM (5985/5986) inbound; all outbound |
| `aws_launch_template.runner` | **Linux runner blueprint** — AMI, instance type, IAM profile, user_data, volume size |
| `aws_launch_template.runner_windows` | **Windows runner blueprint** — same but for Windows |
| `aws_instance.windows` | Static Windows instances (count=0 by default, not used for ephemeral) |
| `data.aws_ami.runner_linux` | Looks up the latest custom AMI tagged `Purpose=github-runner` |
| `data.aws_ami.ubuntu` | Looks up latest Ubuntu 24.04 (fallback reference) |
| `data.aws_ami.windows` | Looks up latest Windows Server 2022 |

### `lambda.tf`

Everything Lambda-related:

| Resource | Purpose |
|---|---|
| `data.archive_file.lambda` | Zips `lambda/index.py` + `lambda/processor.py` → `runner_webhook.zip` |
| `aws_sqs_queue.runner_jobs` | Main job queue (5min visibility timeout, 24h retention) |
| `aws_sqs_queue.runner_dlq` | Dead-letter queue (14 day retention, for inspection) |
| `aws_dynamodb_table.runner_pool` | Tracks active runner count |
| `aws_dynamodb_table_item.runner_pool_counter` | Seeds the `{pk:"pool", active_count:0}` row |
| `aws_iam_role.lambda` | IAM role for both Lambda functions |
| `aws_iam_role_policy.lambda_permissions` | Allows Lambda to: RunInstances, SQS read/write, DynamoDB read/write |
| `aws_lambda_function.webhook` | Lambda 1 (index.py), triggered by API Gateway |
| `aws_lambda_function.processor` | Lambda 2 (processor.py), triggered by SQS |
| `aws_lambda_event_source_mapping` | Wires SQS → processor Lambda (batch size=1) |
| `aws_apigatewayv2_api` | HTTP API Gateway |
| `aws_apigatewayv2_integration` | Connects API Gateway to webhook Lambda |
| `aws_apigatewayv2_route` | `POST /webhook` route |
| `aws_apigatewayv2_stage` | `$default` stage (auto-deploy=true) |
| `aws_lambda_permission` | Allows API Gateway to invoke the webhook Lambda |

### `networking.tf`

Read-only data sources + key pair:

| Resource | Purpose |
|---|---|
| `data.aws_vpc.main` | Looks up your VPC by ID |
| `data.aws_subnet.main` | Looks up your subnet by ID |
| `data.aws_internet_gateway.main` | Confirms internet access exists |
| `aws_key_pair.runner` | Creates the EC2 key pair (only if `key_pair_public_key_path` is set) |

### `variables.tf`

All configurable inputs. Key ones:

| Variable | Current Value | What It Controls |
|---|---|---|
| `aws_region` | `eu-north-1` | Where everything is deployed |
| `vpc_id` | `vpc-0478ef0dcba655d75` | Your VPC |
| `subnet_id` | `subnet-00ef9ebbc8c80cea4` | Your subnet |
| `github_runner_scope` | `org` | Org-level runner (not repo-level) |
| `github_org_name` | `py-libp2p-runners` | The GitHub org runners register to |
| `github_runner_labels` | `self-hosted,linux,x64` | Labels workflows use to target this runner |
| `github_webhook_secret` | `libp2p-runner` | HMAC secret shared with GitHub webhook |
| `github_pat_secret_name` | `/test/1/github_pat` | Path in Secrets Manager |
| `github_pat` | `ghp_...` | The actual PAT (stored in Secrets Manager) |
| `runner_max_pool_size` | `2` | Max concurrent EC2 runners |
| `linux_runner_ami_id` | `ami-06fefbd11d536ceb2` | **Update this after every Packer build** |
| `ubuntu_root_volume_size` | `100` | EBS volume size for runners |
| `ubuntu_instance_count` | `0` | Static instances (0 = ephemeral only) |

### `outputs.tf`

Values printed after `terraform apply`:

| Output | Value | Use |
|---|---|---|
| `webhook_url` | `https://xxx.execute-api.eu-north-1.amazonaws.com/webhook` | Register this in GitHub org webhook settings |
| `runner_launch_template_id` | `lt-0ccf22eb000f5d75c` | Used by Lambda to launch EC2 |
| `sqs_job_queue_url` | SQS URL | Monitor queue depth |
| `sqs_dlq_url` | SQS DLQ URL | Inspect failed jobs |
| `dynamodb_pool_table` | `libp2p-runner-runner-pool` | Check active runner count |

### `terraform.tfvars`

Your actual configuration values. **This file is git-ignored** (contains the PAT). Never commit it.

### `terraform.tfstate` / `terraform.tfstate.backup`

Terraform's record of what exists in AWS. **Never edit manually.** If lost, use `terraform import` to rebuild. Back these up somewhere safe (ideally use S3 remote state).

### `tfplan`

A saved Terraform plan from a previous `terraform plan -out=tfplan` run. Can be applied with `terraform apply tfplan`. Stale after any infrastructure changes.

---

### `lambda/index.py` — Lambda 1: Webhook Receiver

**Triggered by:** API Gateway (`POST /webhook` from GitHub)  
**Timeout:** 10 seconds  
**Purpose:** Fast webhook validation and queuing

Flow:
1. Verifies HMAC-SHA256 signature using `WEBHOOK_SECRET`
2. Ignores non-`workflow_job` events
3. On `action=queued`: checks if labels contain `self-hosted` + `linux` or `windows`
4. Sends a message to SQS with job_id, job_name, labels, runner_type
5. Returns 200 to GitHub immediately (GitHub requires fast response)

**Does NOT launch EC2** — that's Lambda 2's job.

### `lambda/processor.py` — Lambda 2: Job Processor

**Triggered by:** SQS event source mapping (automatic, batch size=1)  
**Timeout:** 30 seconds  
**Purpose:** Pool management + EC2 launch

Flow:
1. Reads `active_count` from DynamoDB
2. If `active_count >= runner_max_pool_size`: does nothing (message returns to SQS after 5min visibility timeout)
3. If `active_count < max`: atomically increments count and calls `ec2:RunInstances`
4. Tags the new instance with `GitHubJobId`, `RunnerName`, `GitHubJobName`
5. On `action=completed`: decrements `active_count` in DynamoDB

**Pool management:** The DynamoDB counter prevents launching more instances than `runner_max_pool_size`. When a job completes, the instance self-terminates AND processor.py decrements the counter.

### `lambda/runner_webhook.zip`

Auto-generated by Terraform's `archive_file` data source. Contains both `.py` files. **Never edit or commit manually** — Terraform regenerates it on every apply if the source files changed.

---

### `user_data.sh.tpl` — Linux EC2 Boot Script

**When it runs:** Once, on first boot of each ephemeral EC2 instance  
**Runs as:** root  
**Template variables** injected by Terraform: `aws_region`, `github_pat_secret_name`, `runner_scope`, `repo_url`, `org_name`, `runner_labels`

What it does:
1. Fetches the GitHub PAT from AWS Secrets Manager
2. Resolves `RunnerName` from EC2 instance tags (set by Lambda at launch)
3. Writes `/etc/github-runner.env` with all runner config
4. Calls `systemctl start github-runner` — the rest happens in the pre-baked scripts

**Important:** This script is intentionally minimal. All the heavy lifting (runner binary, wrapper, entrypoint) is pre-baked into the AMI by Packer. This keeps boot time fast (~30s instead of ~10min).

> ⚠️ **Bug present:** `user_data.sh.tpl` sets `chmod 600` on the env file (root-only). The fix in `provision.sh` sets `640` with `root:actions-runner` ownership. The `user_data.sh.tpl` also needs this fix for production.

### `user_data.ps1.tpl` — Windows EC2 Boot Script

Same concept as the Linux version but for Windows Server. Installs Chocolatey, git, jq, AWS CLI, Docker Desktop, fetches the PAT, downloads and registers the GitHub Actions runner. Windows runners are **not pre-baked** — everything installs at boot time (slower but simpler for Windows).

---

### `packer/github-runner.pkr.hcl` — Packer Build Definition

Defines how to build the Linux runner AMI:
- **Base image:** Latest Ubuntu 24.04 (Noble) from Canonical
- **Instance type:** `t3.xlarge` (4 vCPU / 16 GB) for the build
- **Root volume:** 100 GB gp3
- **Region:** `eu-north-1`
- **Steps:** Upload `provision.sh` → run it as root → smoke test key binaries → create AMI snapshot

Tags the AMI with `Purpose=github-runner` so Terraform's `data.aws_ami.runner_linux` can find it automatically.

### `packer/provision.sh` — The AMI Provisioner

**The most important script in the project.** Runs once during Packer build to install everything into the AMI.

16 steps:

| Step | What It Installs | Why |
|---|---|---|
| 1 | System packages: curl, git, cmake, ninja-build, protoc, libssl-dev, chromium, openjdk-11 | Base tools + per-repo needs |
| 2 | AWS CLI v2 | EC2 self-terminate + Secrets Manager access |
| 3 | Docker CE + Buildx + Compose plugin | All interop tests use Docker |
| 4 | BuildKit config (`/etc/buildkit/buildkitd.toml`) | GCR mirror for docker.io rate limits; also signals to transport-interop action that this is a self-hosted runner |
| 5 | Go 1.25.7 | go-libp2p workflows |
| 6 | Node.js 22 | js-libp2p + transport-interop test runner |
| 7 | uv (Astral) | Fast Python package manager |
| 8 | Python 3.10–3.13 via uv + tox | py-libp2p tox matrix |
| 9 | Rust stable + MSRV 1.88.0 + beta + nightly + wasm32 targets + wasm-pack + tomlq + cargo-deny + cargo-audit | rust-libp2p CI |
| 10 | Nim 2.x (direct tarball from nim-lang.org) | py-libp2p interop tests |
| 11 | Terraform (latest 1.x) | test-plans perf workflow |
| 12 | Verifies Shadow simulator deps (cmake, pkg-config, libglib2.0-dev) | gossipsub-interop |
| 13 | Temurin JDK 11 (via Adoptium APT repo) + JAVA_HOME | jvm-libp2p |
| 14 | `actions-runner` user + sudoers + docker group | Runner process user |
| 15 | GitHub Actions runner binary + OS deps | The actual runner |
| 16 | Bakes in `github-runner-entrypoint.sh`, `github-runner-wrapper.sh`, systemd unit | Fast boot (no re-download at runtime) |

Then cleans up all caches to keep the AMI lean.

### `packer/verify-ami.sh` — AMI Verification Script

Run this on a live instance to verify all tools are installed correctly. Has 16 check sections plus 3 live smoke tests:
- py-libp2p: creates a venv, installs deps, runs `make pr`
- go-libp2p: `go build ./...`
- rust-libp2p: `cargo check --all-features`

```bash
sudo ./packer/verify-ami.sh
sudo ./packer/verify-ami.sh --no-py-venv   # skip the slow live test
```

---

## 5. What Happens After `terraform apply`

```
terraform apply
│
├─ Creates/updates in AWS eu-north-1:
│
│  IAM
│  ├─ Role: libp2p-runner-runner-role
│  ├─ Instance profile: libp2p-runner-runner-profile
│  └─ Role: libp2p-runner-webhook-lambda-role
│
│  Secrets Manager
│  └─ Secret: /test/1/github_pat  (stores your PAT)
│
│  Security Group
│  └─ libp2p-runner-sg  (SSH 22, RDP 3389, WinRM 5985/5986, all egress)
│
│  EC2 Launch Templates
│  ├─ libp2p-runner-runner-*  (Linux, uses AMI from linux_runner_ami_id)
│  └─ libp2p-runner-runner-windows-*  (Windows, uses latest Windows Server 2022)
│
│  SQS
│  ├─ libp2p-runner-runner-jobs  (main queue)
│  └─ libp2p-runner-runner-dlq   (dead-letter queue)
│
│  DynamoDB
│  └─ libp2p-runner-runner-pool  (with seeded {pk:"pool", active_count:0})
│
│  Lambda
│  ├─ libp2p-runner-runner-webhook   (index.py, env: WEBHOOK_SECRET, JOB_QUEUE_URL)
│  └─ libp2p-runner-runner-processor (processor.py, env: LAUNCH_TEMPLATE_ID, DYNAMODB_TABLE, ...)
│
│  API Gateway
│  └─ HTTP API → POST /webhook → webhook Lambda
│      invoke URL printed as output: webhook_url
│
└─ Prints outputs:
    webhook_url            ← Register this in GitHub org settings!
    runner_launch_template_id
    sqs_job_queue_url
    sqs_dlq_url
    dynamodb_pool_table
```

**After apply, one manual step is required:**  
Register the `webhook_url` in GitHub org webhook settings:  
`https://github.com/organizations/py-libp2p-runners/settings/hooks`
- Content type: `application/json`
- Secret: value of `github_webhook_secret` in tfvars
- Events: **Workflow jobs** only

---

## 6. The Full Job Lifecycle

```
1. Developer pushes to py-libp2p repo
   └─ GitHub Actions workflow triggers

2. GitHub sees job with labels: [self-hosted, linux, x64]
   └─ Fires workflow_job webhook (action: queued) to your webhook URL

3. API Gateway receives POST /webhook
   └─ Invokes Lambda 1 (index.py)

4. index.py:
   ├─ Verifies HMAC signature
   ├─ Confirms labels match
   └─ Sends to SQS: {job_id, job_name, labels, runner_type:"linux"}

5. SQS delivers message to Lambda 2 (processor.py)

6. processor.py:
   ├─ Reads active_count from DynamoDB (e.g. 0)
   ├─ 0 < 2 (max_pool_size) → proceed
   ├─ Atomically increments active_count to 1
   └─ Calls ec2:RunInstances with:
       - Launch Template: lt-0ccf22eb000f5d75c
       - Tags: Name, GitHubJobId=<job_id>, RunnerName=ec2-runner-<job_id>

7. EC2 instance boots (AMI: ami-0xxxxxxxxxxxxxxxxx)
   └─ user_data.sh.tpl runs:
       ├─ apt-get update + install curl jq unzip
       ├─ Installs AWS CLI
       ├─ Fetches PAT from Secrets Manager (/test/1/github_pat)
       ├─ Reads RunnerName from EC2 tags via IMDSv2
       ├─ Writes /etc/github-runner.env
       └─ systemctl start github-runner

8. systemd starts github-runner-wrapper.sh
   ├─ Gets INSTANCE_ID + REGION via IMDSv2
   ├─ Reads GitHubJobId tag from EC2
   ├─ Calls GitHub API: GET /repos/.../actions/jobs/<job_id>
   ├─ If job is "completed" or "cancelled" → terminate immediately (job was cancelled while booting)
   └─ If job is "queued" or "in_progress" → proceed

9. github-runner-entrypoint.sh runs:
   ├─ Calls GitHub API: POST /orgs/py-libp2p-runners/actions/runners/registration-token
   ├─ Runs ./config.sh --url https://github.com/py-libp2p-runners --token <reg_token>
   │   --name ec2-runner-<job_id> --labels self-hosted,linux,x64 --ephemeral
   └─ Runs ./run.sh (runner connects to GitHub, picks up the job)

10. Job runs (could take seconds to hours)
    └─ All tools are pre-installed in the AMI — no setup time

11. Job completes (pass or fail)
    └─ ./run.sh exits

12. github-runner-wrapper.sh continues:
    └─ aws ec2 terminate-instances --instance-ids <INSTANCE_ID>
       (instance self-destructs)

13. processor.py receives "completed" webhook event:
    └─ Decrements active_count in DynamoDB back to 0
```

---

## 7. The AMI Build Process (Packer)

The AMI is the "golden image" — everything pre-installed so runners boot fast.

### How to build

```bash
cd packer/

packer init .

packer build \
  -var "aws_region=eu-north-1" \
  -var "go_version=1.25.7" \
  -var "node_version=22" \
  -var "rust_toolchain=stable" \
  github-runner.pkr.hcl
```

Packer:
1. Launches a `t3.xlarge` EC2 in eu-north-1
2. SSHs in and uploads `provision.sh`
3. Runs `provision.sh` as root (takes ~30-60 min)
4. Runs smoke tests
5. Creates an EBS snapshot → registers it as an AMI
6. Terminates the build instance
7. Prints: `AMIs were created: eu-north-1: ami-0xxxxxxxxxxxxxxxxx`

### After build: update tfvars

```bash
# In terraform.tfvars:
linux_runner_ami_id = "ami-0xxxxxxxxxxxxxxxxx"   # new AMI ID

# Apply so the Launch Template picks it up
terraform apply
```

New jobs will use the new AMI. In-flight jobs on old AMIs are unaffected.

### When to rebuild the AMI

- Any change to `provision.sh`
- Go/Node/Rust version bumps
- New tool required by a workflow
- Ubuntu security patches (every few months)

---

## 8. Files That Are NOT Currently Used

| File | Why It Exists | Safe to Delete? |
|---|---|---|
| `entrypoint.sh` | Old Docker-based entrypoint from before the AMI approach. The runner was originally run in a Docker container. Now the runner runs directly on EC2 via systemd. | ✅ Yes |
| `test-runner.ps1` | Old Windows test script, predates the current Windows `user_data.ps1.tpl` approach. | ✅ Yes |
| `logs.txt` | Scratch log file from manual testing sessions. | ✅ Yes |
| `extra/logs.txt` | Same — scratch log from testing. | ✅ Yes |
| `tfplan` | Saved plan from a previous run. Goes stale quickly. | ✅ Yes (regenerate with `terraform plan -out=tfplan`) |
| `extra/` (entire folder) | The libp2p repos were cloned here to analyse CI dependencies when building `provision.sh`. They're not used at runtime. | ✅ Yes (large, ~GB) |
| `ubuntu_instance_count` in tfvars | Set to `0`. The `aws_instance.ubuntu` resource in main.tf is removed; this variable is vestigial. | — (harmless) |

---

## 9. Key Configuration Values

### Things you WILL need to update

| What | Where | When |
|---|---|---|
| `linux_runner_ami_id` | `terraform.tfvars` | After every Packer build |
| `github_pat` | `terraform.tfvars` | When PAT expires (classic PATs expire) |
| `go_version` | `terraform.tfvars` + Packer `-var` | When go-libp2p bumps `go.mod` |
| `runner_max_pool_size` | `terraform.tfvars` | If you need more concurrent jobs |
| `ubuntu_instance_type` | `terraform.tfvars` | If jobs need more CPU/RAM |

### Things that rarely change

| What | Where | Current Value |
|---|---|---|
| AWS region | `terraform.tfvars` | `eu-north-1` |
| VPC / subnet | `terraform.tfvars` | Fixed to your VPC |
| GitHub org | `terraform.tfvars` | `py-libp2p-runners` |
| Runner labels | `terraform.tfvars` | `self-hosted,linux,x64` |
| Webhook secret | `terraform.tfvars` | `libp2p-runner` (also set in GitHub) |
| PAT secret path | `terraform.tfvars` | `/test/1/github_pat` |

---

## 10. Day-to-Day Operations

### Check how many runners are active right now

```bash
aws dynamodb get-item \
  --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --key '{"pk":{"S":"pool"}}' \
  --query 'Item.active_count.N' \
  --output text
```

### Check the job queue depth

```bash
aws sqs get-queue-attributes \
  --region eu-north-1 \
  --queue-url $(terraform output -raw sqs_job_queue_url) \
  --attribute-names ApproximateNumberOfMessages
```

### Check Lambda logs

```bash
# Webhook Lambda
aws logs tail /aws/lambda/libp2p-runner-runner-webhook \
  --region eu-north-1 --follow

# Processor Lambda
aws logs tail /aws/lambda/libp2p-runner-runner-processor \
  --region eu-north-1 --follow
```

### Check runner logs on a live instance

```bash
ssh ubuntu@<PUBLIC_IP>
sudo journalctl -fu github-runner
```

### Reset active_count if it gets stuck (e.g. after a crash)

```bash
aws dynamodb put-item \
  --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --item '{"pk":{"S":"pool"},"active_count":{"N":"0"}}'
```

### Rotate the GitHub PAT

```bash
# 1. Generate new classic PAT at https://github.com/settings/tokens
#    Scopes: admin:org, repo, workflow
#    Authorize SSO for py-libp2p-runners org

# 2. Update terraform.tfvars
github_pat = "ghp_NEW_TOKEN_HERE"

# 3. Apply (updates Secrets Manager)
terraform apply

# 4. In-flight instances will use the old token until they terminate.
#    New instances get the new token.
```

---

## 11. How to Rebuild the AMI

```bash
# 1. Make your changes to provision.sh

# 2. Build
cd packer/
packer build \
  -var "aws_region=eu-north-1" \
  -var "go_version=1.25.7" \
  -var "node_version=22" \
  -var "rust_toolchain=stable" \
  github-runner.pkr.hcl

# 3. Note the new AMI ID from output
# AMIs were created:
# eu-north-1: ami-0xxxxxxxxxxxxxxxxx

# 4. Update terraform.tfvars
# linux_runner_ami_id = "ami-0xxxxxxxxxxxxxxxxx"

# 5. Apply
cd ..
terraform apply

# 6. (Optional) Deregister old AMI to avoid clutter
aws ec2 deregister-image --region eu-north-1 --image-id ami-OLDID
```

---

## 12. How to Register a Manual Test Runner

Use this when you want to test the AMI without triggering a real workflow:

```bash
# 1. Launch instance from the AMI
aws ec2 run-instances \
  --region eu-north-1 \
  --image-id ami-0xxxxxxxxxxxxxxxxx \
  --instance-type t3.xlarge \
  --key-name libp2p-runner \
  --subnet-id subnet-00ef9ebbc8c80cea4 \
  --associate-public-ip-address \
  --block-device-mappings 'DeviceName=/dev/sda1,Ebs={VolumeSize=100,VolumeType=gp3}' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=runner-manual-test}]' \
  --query 'Instances[0].InstanceId' --output text

# 2. SSH in
ssh ubuntu@<PUBLIC_IP>

# 3. Write the env file
sudo tee /etc/github-runner.env << 'EOF'
ACCESS_TOKEN=ghp_YOUR_CLASSIC_PAT
RUNNER_SCOPE=org
REPO_URL=
ORG_NAME=py-libp2p-runners
LABELS=self-hosted,linux,x64
RUNNER_NAME=manual-test-runner
EOF
sudo chmod 640 /etc/github-runner.env
sudo chown root:actions-runner /etc/github-runner.env

# 4. Run the entrypoint directly (bypasses wrapper = no auto-terminate)
sudo -u actions-runner bash -c '
  set -a; source /etc/github-runner.env; set +a
  /usr/local/bin/github-runner-entrypoint.sh
'
# Runner registers, picks up one job, then exits back to shell prompt.
# Instance stays alive. Re-run the above for each additional job.

# 5. When done, terminate manually
aws ec2 terminate-instances --region eu-north-1 --instance-ids i-XXXXXXXXXX
```

---

## 13. Debugging Runbook

### Problem: Jobs stay queued, no runner picks them up

```bash
# Check Lambda processor logs
aws logs tail /aws/lambda/libp2p-runner-runner-processor --region eu-north-1

# Check SQS queue depth
aws sqs get-queue-attributes --region eu-north-1 \
  --queue-url <sqs_job_queue_url> \
  --attribute-names ApproximateNumberOfMessages

# Check if active_count is stuck at max
aws dynamodb get-item --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --key '{"pk":{"S":"pool"}}'
# If stuck: reset to 0 (see Day-to-Day Operations above)
```

### Problem: Runner registers but job fails immediately

```bash
ssh ubuntu@<INSTANCE_IP>
sudo journalctl -u github-runner --no-pager
# Look for errors in the job output
ls /actions-runner/_work/
```

### Problem: EC2 instance launches but runner never registers

```bash
ssh ubuntu@<INSTANCE_IP>
sudo cat /var/log/github-runner-init.log
# Check if PAT fetch failed, or user_data had errors
sudo cat /var/log/cloud-init-output.log
```

### Problem: 401 from GitHub API

- PAT has expired → rotate it (see Day-to-Day Operations)
- PAT doesn't have `admin:org` scope → regenerate with correct scopes
- PAT not SSO-authorized for `py-libp2p-runners` → go to github.com/settings/tokens → Configure SSO → Authorize

### Problem: Instance runs out of disk space

```bash
sudo docker system prune -af --volumes
sudo rm -rf /root/.cache /root/go
df -h
# If still full, the EBS volume needs to be larger
# Increase ubuntu_root_volume_size in terraform.tfvars and rebuild AMI
```

### Problem: active_count never decrements

This means the `action=completed` webhook isn't being received. Check:
1. The GitHub webhook is configured for "Workflow jobs" events (not just "Workflow runs")
2. Lambda webhook logs for `action=completed` events
3. The `action=completed` path in `processor.py`

---

## 14. Cost Model

| Component | Cost |
|---|---|
| EC2 (t3.xlarge) | ~$0.166/hour × actual job duration |
| Lambda | ~$0 (free tier covers millions of invocations) |
| SQS | ~$0 (free tier covers millions of messages) |
| DynamoDB | ~$0 (on-demand, minimal reads/writes) |
| Secrets Manager | ~$0.40/month per secret |
| API Gateway | ~$0 (free tier covers 1M requests/month) |
| EBS (100 GB gp3) | ~$0.08/GB/month × hours running |

**Total when idle:** ~$0.50/month (just Secrets Manager)  
**Per job (1 hour):** ~$0.17

---

## 15. Known Gotchas

| Gotcha | Detail |
|---|---|
| **`/etc/github-runner.env` permissions** | Must be `640` owned by `root:actions-runner`. If `600`, the `actions-runner` user can't read it and all env vars are empty → 401. `user_data.sh.tpl` currently sets `600` — this needs fixing. |
| **IMDSv2 required** | The wrapper uses IMDSv2 (token-based metadata). AWS now defaults all new instances to IMDSv2-required. Old scripts using IMDSv1 get 401. |
| **Ephemeral runner de-registration** | After a job, `--ephemeral` makes the runner auto-deregister from GitHub. No manual cleanup needed. |
| **PAT must be Classic** | Fine-grained PATs cannot register org-level runners. Must use classic PAT with `admin:org` scope. |
| **SSO authorization** | Even with correct scopes, the PAT must be SSO-authorized for the `py-libp2p-runners` org at github.com/settings/tokens. |
| **DynamoDB count drift** | If an instance crashes without completing the job, `active_count` won't decrement. Monitor and reset manually if jobs stop being picked up. |
| **Chromium on Ubuntu 24.04** | Ubuntu 24.04 ships chromium as a snap (not an apt package). Snaps don't work in headless EC2 builds. The provision.sh uses `ppa:xtradeb/apps` to get a real apt-installed chromium. |
| **Adoptium JDK repo** | The Adoptium (Temurin) APT repo codename must be hardcoded to `noble` for Ubuntu 24.04 — `$(lsb_release -cs)` returns `noble` but the repo may not have it under that alias yet. |
| **Nim installation** | Do NOT use choosenim or init.sh — they have URL and path issues. Install Nim directly from the nim-lang.org binary tarball. |
| **Cargo tools survive cleanup** | The final cleanup in provision.sh removes `cargo/registry` and `cargo/git` (source cache) but intentionally keeps the installed binaries in `cargo/bin` (wasm-pack, tomlq, cargo-deny, cargo-audit). |
