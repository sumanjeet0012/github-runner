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
