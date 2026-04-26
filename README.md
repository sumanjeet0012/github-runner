# github-runner

A Terraform project to provision configurable numbers of **Ubuntu** and **Windows** EC2 instances on AWS.

---

## Project structure
  
```
.
├── main.tf            # Provider, AMI data sources, security group, instances
├── variables.tf       # All input variables with descriptions & defaults
├── outputs.tf         # Useful outputs (IDs, IPs, AMI IDs)
├── terraform.tfvars   # Your actual values (git-ignored)
└── README.md
```

---

## Prerequisites

| Tool | Version |
|------|---------|
| [Terraform](https://developer.hashicorp.com/terraform/downloads) | ≥ 1.3.0 |
| [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) | any |
| AWS credentials configured (`aws configure` or env vars) | – |

---

## Quick start

```bash
# 1. Clone and enter the repo
cd github-runner

# 2. Fill in your values
cp terraform.tfvars terraform.tfvars   # already present – edit it

# 3. Initialise Terraform
terraform init

# 4. Preview the plan
terraform plan

# 5. Apply
terraform apply
```

---

## Configuring instance counts

Edit **`terraform.tfvars`** (or pass `-var` flags):

```hcl
ubuntu_instance_count  = 2   # spin up 2 Ubuntu instances
windows_instance_count = 1   # spin up 1 Windows instance
```

Set either count to `0` to skip that OS entirely.

---

## Key variables

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region |
| `vpc_id` | **required** | VPC to deploy into |
| `subnet_id` | **required** | Subnet to deploy into |
| `key_name` | `null` | EC2 Key Pair name |
| `ubuntu_instance_count` | `1` | Number of Ubuntu instances |
| `ubuntu_instance_type` | `t3.micro` | EC2 type for Ubuntu |
| `ubuntu_root_volume_size` | `20` | Root disk size (GiB) |
| `windows_instance_count` | `1` | Number of Windows instances |
| `windows_instance_type` | `t3.medium` | EC2 type for Windows |
| `windows_root_volume_size` | `50` | Root disk size (GiB) |
| `allowed_cidr_blocks` | `["0.0.0.0/0"]` | IPs allowed for SSH/RDP |
| `github_runner_scope` | `repo` | `repo` or `org` |
| `github_repo_url` | `""` | Full repo URL (scope=repo) |
| `github_org_name` | `""` | GitHub org name (scope=org) |
| `github_runner_labels` | `self-hosted,linux,x64` | Comma-separated runner labels |
| `github_runner_name_prefix` | `ec2-runner` | Prefix for runner name |

---

## GitHub Actions Runner (Ubuntu) – Ephemeral per-job

Every GitHub Actions job gets a **brand-new EC2 instance** that registers as a runner, executes the job, and then **self-terminates**. No standing instances, no stale state.

### Architecture

```
GitHub workflow_job event
  └─ API Gateway POST /webhook
       └─ Lambda (runner_webhook)
            ├─ verifies HMAC signature
            └─ on "queued" → EC2 RunInstances (Launch Template)
                  └─ EC2 instance boots
                       ├─ user_data: install deps, fetch PAT from Secrets Manager
                       ├─ register as ephemeral runner (--ephemeral flag)
                       ├─ run ONE job
                       └─ self-terminate via aws ec2 terminate-instances
```

### New resources created by Terraform

| Resource | Purpose |
|---|---|
| `aws_launch_template.runner` | Blueprint for ephemeral runner instances |
| `aws_lambda_function.webhook` | Receives GitHub webhook, launches EC2 |
| `aws_apigatewayv2_api.webhook` | HTTP API endpoint for the webhook |
| `aws_iam_role.lambda` | IAM role for Lambda (EC2 RunInstances + PassRole) |

### Setup steps

**1. Set your webhook secret in `terraform.tfvars`:**

```hcl
github_webhook_secret = "some-long-random-string"
```

**2. Apply:**

```bash
terraform apply
```

**3. Copy the webhook URL from the output:**

```bash
terraform output webhook_url
# e.g. https://abc123.execute-api.eu-north-1.amazonaws.com/webhook
```

**4. Register the webhook in GitHub:**

Go to **https://github.com/organizations/py-libp2p-runners/settings/hooks** → Add webhook:
- **Payload URL**: the URL from step 3
- **Content type**: `application/json`
- **Secret**: same value as `github_webhook_secret`
- **Events**: select **Workflow jobs** only

**5. Trigger a workflow** — a fresh EC2 instance will spin up, pick up the job, and terminate itself automatically.

### Runner variables in `terraform.tfvars`

```hcl
github_runner_scope       = "org"
github_org_name           = "py-libp2p-runners"
github_runner_labels      = "self-hosted,linux,x64"
github_runner_name_prefix = "ec2-runner"
github_webhook_secret     = "your-secret-here"
```

### Checking runner logs on a live instance

```bash
ssh -i ~/.ssh/libp2p-runner.pem ubuntu@<instance_public_ip>

# Bootstrap log
sudo tail -f /var/log/github-runner-init.log

# Runner registration + job output
sudo journalctl -u github-runner -f
```

---

## Connecting to instances

### Ubuntu (SSH)
```bash
ssh -i ~/.ssh/<your-key>.pem ubuntu@<ubuntu_public_ip>
```

### Windows (RDP)
1. Retrieve the encrypted password:
   ```bash
   terraform output -json windows_password_data
   ```
2. Decrypt it with your private key in the AWS Console → EC2 → **Get Windows password**.
3. Connect via RDP to `<windows_public_ip>` with user `Administrator`.

---

## GitHub PAT – AWS Secrets Manager

The project stores a GitHub Personal Access Token (PAT) securely in **AWS Secrets Manager**.

### How it works

1. Set the two variables in `terraform.tfvars`:

   ```hcl
   github_pat_secret_name = "github-pat"           # name for the secret in AWS
   github_pat             = "ghp_xxxxxxxxxxxx"      # your actual PAT value
   ```

2. Run `terraform apply` — Terraform creates:
   - An **AWS Secrets Manager secret** with the given name.
   - A **secret version** containing the PAT as a plain string.

3. After apply, the secret ARN is printed as an output:

   ```bash
   terraform output github_pat_secret_arn
   ```

### Retrieving the PAT later

```bash
# via AWS CLI
aws secretsmanager get-secret-value \
  --secret-id github-pat \
  --query SecretString \
  --output text
```

### Security notes

- `github_pat` is marked **`sensitive = true`** in Terraform — it will never appear in plan/apply output.
- `terraform.tfvars` is **git-ignored** — never commit it.
- In production, restrict access to the secret via an IAM resource policy.

---

## Destroy

```bash
terraform destroy
```
