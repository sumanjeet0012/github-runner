# Windows GitHub Actions Runner Setup

## Overview

Your GitHub Actions runner system now supports both **Linux** and **Windows** ephemeral runners. Jobs are automatically routed to the appropriate OS based on their labels.

## Architecture Changes

### Lambda Functions (Updated)

#### 1. **Webhook Receiver** (`lambda/index.py`)
- **Before**: Skipped all Windows jobs with `WINDOWS_SKIP` filter
- **Now**: Accepts both Linux and Windows jobs
- **Label Logic**:
  - `linux` label → routes to Linux runner
  - `windows` label → routes to Windows runner
  - Requires `self-hosted` label in all cases
  - If no OS label specified → defaults to Linux

#### 2. **Job Processor** (`lambda/processor.py`)
- **New**: Determines runner type from job labels
- **New**: Selects appropriate launch template:
  - Linux jobs → `LAUNCH_TEMPLATE_ID` (t3.micro)
  - Windows jobs → `LAUNCH_TEMPLATE_ID_WINDOWS` (t3.medium)
- **Environment Variables** (added):
  - `LAUNCH_TEMPLATE_ID_WINDOWS` = Windows launch template ID

### Infrastructure (New)

#### 1. **Windows Launch Template** (`aws_launch_template.runner_windows`)
- **Image**: Windows Server 2022 Base AMI
- **Instance Type**: `t3.medium` (minimum recommended for Windows)
- **Root Volume**: 50 GiB (Windows OS footprint)
- **User Data**: PowerShell script (`user_data.ps1.tpl`)

#### 2. **Windows User Data Script** (`user_data.ps1.tpl`)
Equivalent to the Linux `user_data.sh.tpl` but for Windows:
- Installs Chocolatey package manager
- Installs required tools: curl, jq, AWS CLI v2, Git
- Fetches GitHub PAT from Secrets Manager
- Downloads GitHub Actions Runner
- Configures runner with GitHub organization/repo
- Creates scheduled task for ephemeral runner execution
- Launches runner immediately after configuration
- **Self-terminates** after job completion

### Configuration (New Variables)

#### New Variable: `github_runner_labels_windows`
```hcl
variable "github_runner_labels_windows" {
  description = "Comma-separated list of labels for Windows runners"
  default     = "self-hosted,windows,x64"
}
```

#### Updated: `terraform.tfvars`
```hcl
github_runner_labels          = "self-hosted,linux,x64"
github_runner_labels_windows  = "self-hosted,windows,x64"
```

---

## How to Test Windows Runners

### 1. Create a Test Workflow

Create `.github/workflows/test-windows.yml`:

```yaml
name: Test Windows Runner

on:
  push:
    branches: [ main ]
  pull_request:

jobs:
  test-windows:
    runs-on: [ self-hosted, windows, x64 ]
    steps:
      - uses: actions/checkout@v4
      
      - name: Display Windows Info
        run: |
          Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
          Write-Host "Windows OS: $(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty Caption)"
          Get-Disk | Format-Table
      
      - name: Test Python
        run: |
          python --version
          pip --version
      
      - name: Run Tests
        run: |
          # Your Windows test commands here
          echo "Windows runner is working!"
```

### 2. Label Requirements for Windows Jobs

Your GitHub Actions workflow **must** use these labels:

```yaml
runs-on: [self-hosted, windows, x64]
```

The system filters jobs based on:
- **Must have**: `self-hosted` (required for all jobs)
- **OS selector**: `windows` (routes to Windows runner) OR `linux` (routes to Linux runner)
- **Optional**: `x64` (architecture label)

### 3. Monitor Job Execution

#### Via CloudWatch Logs

```bash
# Watch processor Lambda logs
aws logs tail /aws/lambda/libp2p-runner-runner-processor \
  --region eu-north-1 --follow

# Filter for Windows job launches
aws logs tail /aws/lambda/libp2p-runner-runner-processor \
  --region eu-north-1 \
  --filter-pattern "windows"
```

#### Via AWS Console

1. Go to **EC2 → Instances**
2. Look for instances with tag `OS=Windows`
3. Each Windows instance runs one job then self-terminates
4. Instance name format: `libp2p-runner-{JOB_ID}`

#### Via GitHub

1. Go to your GitHub repo/org
2. **Settings → Runner groups**
3. Watch runners appear with name `ec2-runner-{JOB_ID}` and disappear after job

---

## Key Differences: Linux vs Windows

| Aspect | Linux | Windows |
|--------|-------|---------|
| **OS** | Ubuntu 24.04 LTS | Windows Server 2022 |
| **Instance Type** | `t3.micro` (1 vCPU, 1 GB RAM) | `t3.medium` (2 vCPU, 4 GB RAM) |
| **Root Volume** | 20 GiB | 50 GiB |
| **User Data** | Bash script | PowerShell script |
| **Job Label** | `linux` | `windows` |
| **Startup Time** | ~2-3 min | ~4-5 min (Windows slower) |
| **Cost/Hour** | ~$0.0104 | ~0.0416 (4x more) |
| **Pool Limit** | Same `runner_max_pool_size` (default: 12) | Same pool for both |

### Important Notes on Windows

1. **Instance Type**: `t3.micro` is insufficient for Windows. Minimum is `t3.medium`
   - Windows Server 2022 has higher resource requirements
   - If you need smaller, consider `t3.small` (carefully tested)

2. **Costs**: Windows instances are ~4x more expensive than t3.micro
   - Plan your workload accordingly
   - Consider using Windows only for workflows that actually need it

3. **Startup Time**: Windows boots slower than Linux
   - Expect 4-5 minutes from job queued → runner ready
   - Linux: ~2-3 minutes

4. **Available Tools**: 
   - PowerShell Core 7 (available via Chocolatey)
   - Git (installed in user_data)
   - AWS CLI v2 (installed in user_data)
   - Python (can be installed via Chocolatey if needed)

---

## Configuration & Customization

### Adjust Windows Instance Type

Edit `terraform.tfvars`:

```hcl
windows_instance_type = "t3.small"  # or t3.medium, t3.large, etc.
```

Then:
```bash
terraform apply
```

### Add Custom Windows Tools

Edit `user_data.ps1.tpl` in the tool section:

```powershell
Log "Installing Node.js..."
choco install -y nodejs
```

Redeploy:
```bash
terraform apply -auto-approve
```

### Adjust Pool Limits

The `runner_max_pool_size` applies to **both** Linux and Windows combined:

```hcl
runner_max_pool_size = 12  # Total: up to 12 Linux + Windows instances combined
```

If you want to limit Windows specifically, you'd need to modify `processor.py`:

```python
# Pseudo-code (not implemented)
if runner_type == "windows":
    max_windows = int(os.environ.get("MAX_WINDOWS_POOL", "5"))
    if windows_active >= max_windows:
        raise Exception("windows-pool-full")
```

---

## Troubleshooting

### Windows Instance Won't Start Job

**Symptom**: Instance appears in EC2 but job status remains "queued"

**Diagnosis**:
```bash
# Get instance ID from AWS console or:
aws ec2 describe-instances \
  --region eu-north-1 \
  --filters "Name=tag:OS,Values=Windows" \
  --query 'Reservations[].Instances[].InstanceId'

# SSH into instance (requires RDP or Systems Manager Session Manager)
# Then check logs:
# - C:\Logs\github-runner-init.log (setup errors)
# - C:\Logs\github-runner-wrapper.log (runner execution)
```

### PowerShell Execution Errors

If you see execution policy errors:
- The script uses `Set-ExecutionPolicy Bypass` at the top
- If it still fails, the instance's Windows Defender might be blocking

### Connectivity Issues

**Problem**: Runner can't reach GitHub API or download runner

**Fix**:
1. Check security group allows outbound HTTPS (port 443)
2. Verify NAT or IGW is configured correctly
3. Check VPC has internet access

---

## Environment Variables (Lambda)

### Webhook Receiver: `index.handler`

```
WEBHOOK_SECRET  = "${var.github_webhook_secret}"
JOB_QUEUE_URL   = "${aws_sqs_queue.runner_jobs.url}"
```

### Processor: `processor.handler`

```
LAUNCH_TEMPLATE_ID         = "${aws_launch_template.runner.id}"
LAUNCH_TEMPLATE_ID_WINDOWS = "${aws_launch_template.runner_windows.id}"
LAUNCH_TEMPLATE_VERSION    = "$Latest"
INSTANCE_TYPE              = "${var.ubuntu_instance_type}"
RUNNER_NAME_PREFIX         = "${var.github_runner_name_prefix}"
MAX_POOL_SIZE              = "${var.runner_max_pool_size}"
DYNAMODB_TABLE             = "${aws_dynamodb_table.runner_pool.name}"
JOB_QUEUE_URL              = "${aws_sqs_queue.runner_jobs.url}"
```

---

## Job Routing Logic

```
GitHub sends workflow_job webhook
    ↓
Webhook Lambda (index.py) receives event
    ↓
Extract labels: ["self-hosted", "windows", "x64"]
    ↓
Check: has "self-hosted"? YES ✓
Check: has "windows" or "linux"? → "windows" detected
    ↓
Route to: WINDOWS runner type
    ↓
SQS message includes labels: ["self-hosted", "windows", "x64"]
    ↓
Processor Lambda reads from SQS
    ↓
get_runner_type(labels) → detects "windows"
    ↓
Use LAUNCH_TEMPLATE_ID_WINDOWS
    ↓
Launch t3.medium Windows instance
    ↓
Instance boots, runs user_data.ps1.tpl
    ↓
Runner registers with GitHub as Windows runner
    ↓
Job executes on Windows runner
    ↓
Runner exits (ephemeral mode)
    ↓
Instance self-terminates
    ↓
DynamoDB pool count decremented
```

---

## Common GitHub Workflow Labels

### Linux Jobs
```yaml
runs-on: [ self-hosted, linux, x64 ]
```

### Windows Jobs
```yaml
runs-on: [ self-hosted, windows, x64 ]
```

### Specify Both (workflow runs on both)
```yaml
strategy:
  matrix:
    os: [linux, windows]
jobs:
  build:
    runs-on: [ self-hosted, "${{ matrix.os }}", x64 ]
```

---

## Next Steps

1. **Test**: Push a workflow with `runs-on: [ self-hosted, windows, x64 ]`
2. **Monitor**: Watch CloudWatch logs and EC2 console
3. **Adjust**: Modify `terraform.tfvars` if needed and re-run `terraform apply`
4. **Optimize**: Fine-tune labels, instance types, and pool size based on usage

---

## Architecture Diagram

```
GitHub Webhook (workflow_job)
    ↓
API Gateway → Webhook Lambda (index.py)
    ├─ Extract labels
    ├─ Route by OS (linux/windows)
    └─ Send to SQS
         ↓
    SQS Queue (job buffer)
         ↓
Processor Lambda (processor.py) ← triggered every 5s
    ├─ Check DynamoDB pool count
    ├─ Determine runner type from labels
    ├─ Select launch template (Linux or Windows)
    └─ Launch EC2 instance
         ↓
EC2 Instance (ephemeral)
    ├─ Run user_data script
    ├─ Register with GitHub
    ├─ Execute job
    ├─ Send completed webhook
    └─ Self-terminate
         ↓
DynamoDB: Decrement pool count
    ↓
Loop: Next job from SQS queue
```

---

## Support & Debugging

For issues, check:
1. **CloudWatch Logs**: `/aws/lambda/libp2p-runner-runner-processor`
2. **SQS Queue**: Dead-letter queue for message inspection
3. **DynamoDB**: `libp2p-runner-runner-pool` table for pool counter state
4. **EC2 Tags**: Filter by `Role=github-runner` to see runner instances

Happy automating! 🚀
