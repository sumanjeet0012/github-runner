# GitHub Actions Ephemeral Runner — Architecture & Troubleshooting Guide

---

## Table of Contents

1. [Overview](#overview)
2. [Where the Lambda Functions Live](#where-the-lambda-functions-live)
3. [Full End-to-End Flow](#full-end-to-end-flow)
4. [Lambda 1 — Webhook Receiver (index.py)](#lambda-1--webhook-receiver-indexpy)
5. [Lambda 2 — Job Processor (processor.py)](#lambda-2--job-processor-processorpy)
6. [Pool Management — DynamoDB Counter](#pool-management--dynamodb-counter)
7. [SQS Queue — The Backbone](#sqs-queue--the-backbone)
8. [EC2 Boot Sequence](#ec2-boot-sequence)
9. [Infrastructure Components Reference](#infrastructure-components-reference)
10. [Issues Encountered & Root Causes](#issues-encountered--root-causes)
11. [Debugging Cheatsheet](#debugging-cheatsheet)

---

## Overview

This project runs **ephemeral GitHub Actions self-hosted runners** on AWS EC2.

**Ephemeral** means every GitHub Actions job gets a **brand-new EC2 instance** that:
1. Boots fresh from a Launch Template
2. Installs the GitHub Actions runner binary
3. Fetches the GitHub PAT from AWS Secrets Manager
4. Registers itself with GitHub as a one-job runner (`--ephemeral`)
5. Picks up **exactly one job**
6. **Self-terminates** after the job finishes (pass or fail)

There are **no standing EC2 instances**. Cost is zero when no jobs are running.

---

## Where the Lambda Functions Live

This is the most important thing to understand first.

### Code location on disk

```
github-runner/
├── lambda/
│   ├── index.py           <- Lambda 1: Webhook Receiver  (handler = index.handler)
│   ├── processor.py       <- Lambda 2: Job Processor     (handler = processor.handler)
│   └── runner_webhook.zip <- Auto-generated ZIP (both files packaged together)
└── lambda.tf              <- Terraform that deploys both Lambdas to AWS
```

Both Python files are **zipped together** into a single `runner_webhook.zip` by Terraform's `archive_file` data source. That ZIP is uploaded to AWS Lambda as the deployment package for **both** functions — each function just points to a different handler (`index.handler` vs `processor.handler`).

### Where they run (AWS)

Both Lambda functions run **inside AWS eu-north-1**, not on your laptop. They are serverless — AWS manages the servers, you only pay per invocation (milliseconds of compute).

```
Your laptop                     AWS eu-north-1
──────────────────              ─────────────────────────────────────────────
terraform apply  ──deploys──>   Lambda: libp2p-runner-runner-webhook  (index.py)
                                Lambda: libp2p-runner-runner-processor (processor.py)
                                SQS:    libp2p-runner-runner-jobs
                                DynamoDB: libp2p-runner-runner-pool
                                EC2 Launch Template: lt-0ccf22eb000f5d75c
```

### How Terraform deploys them

```hcl
# Terraform zips both .py files together
data "archive_file" "lambda" {
  source_dir  = "./lambda"           # picks up index.py + processor.py
  output_path = "./lambda/runner_webhook.zip"
}

# Lambda 1 -- points to index.handler inside the ZIP
resource "aws_lambda_function" "webhook" {
  filename = data.archive_file.lambda.output_path
  handler  = "index.handler"         # calls handler() in index.py
  runtime  = "python3.12"
  timeout  = 10
}

# Lambda 2 -- same ZIP, different handler
resource "aws_lambda_function" "processor" {
  filename = data.archive_file.lambda.output_path
  handler  = "processor.handler"     # calls handler() in processor.py
  runtime  = "python3.12"
  timeout  = 30
}
```

### What triggers each Lambda

| Lambda | Trigger | Direction |
|---|---|---|
| `index.py` (webhook receiver) | **API Gateway** — GitHub POSTs to the webhook URL | GitHub -> HTTPS -> API Gateway -> Lambda |
| `processor.py` (job processor) | **SQS** — automatically when a message arrives in the queue | SQS event source mapping -> Lambda |

The processor Lambda is **never called directly by humans or GitHub**. AWS wakes it up automatically whenever a message appears in the SQS queue.

---

## Full End-to-End Flow

```
Developer pushes code to GitHub
        |
        v
GitHub evaluates the workflow YAML
(.github/workflows/*.yml)
        |
        v
GitHub sees:  runs-on: [self-hosted, linux, x64]
        |
        v  (one event per job)
GitHub sends HTTP POST to webhook URL:
  https://nxw9q3ngla.execute-api.eu-north-1.amazonaws.com/webhook
  Header: X-GitHub-Event: workflow_job
  Header: X-Hub-Signature-256: sha256=<hmac-of-body>
  Body:   {"action": "queued", "workflow_job": {"id": 123, "name": "tox", "labels": [...]}}
        |
        v
AWS API Gateway (HTTP API)
  - Receives the HTTPS POST
  - Passes it to Lambda 1 (webhook receiver)
  - Returns whatever Lambda 1 returns to GitHub immediately
        |
        v
Lambda 1: index.py  (runs in AWS, ~5ms)
  1. Verify HMAC signature (X-Hub-Signature-256 vs WEBHOOK_SECRET)
  2. Check X-GitHub-Event == "workflow_job"
  3. Filter labels: if "windows" in labels -> skip (not our runner)
  4. If action == "queued"    -> send message to SQS queue
  5. If action == "completed" -> send message to SQS queue
  6. Return HTTP 200 to GitHub immediately
  (GitHub only waits ~10s for a response -- this Lambda never blocks)
        |
        v
SQS Queue: libp2p-runner-runner-jobs
  - Message is durably stored
  - Retained for 24 hours (matches GitHub's job TTL)
  - If pool is full: message becomes invisible for 5 min, then retried automatically
  - maxReceiveCount = 1000 (effectively never sent to DLQ)
        |
        v  (AWS wakes up Lambda 2 automatically, up to 5s batching window)
Lambda 2: processor.py  (runs in AWS, ~1-3s)

  +-- If action == "completed" --------------------------------------------+
  |  Read DynamoDB active_count                                            |
  |  Decrement active_count by 1 (atomic, conditional: never below 0)     |
  |  Log: "Job 123 completed. Pool active_count now 4"                    |
  +------------------------------------------------------------------------+

  +-- If action == "queued" -----------------------------------------------+
  |  Read DynamoDB active_count                                            |
  |  If active >= MAX_POOL_SIZE (5):                                       |
  |    Log: "Pool full (5/5). Job 123 will be retried in ~5 min"          |
  |    raise Exception("pool-full-retry")                                  |
  |    -> SQS hides message for 300s, then retries automatically           |
  |    -> No EC2 launched, no job lost                                     |
  |                                                                        |
  |  If active < MAX_POOL_SIZE:                                            |
  |    Increment active_count by 1 (atomic)                               |
  |    Call EC2 RunInstances with Launch Template                          |
  |    Tag instance: Name=ec2-runner-123, Role=github-runner, etc.        |
  |    Log: "Launched i-0abc123 for job 123 (tox)"                        |
  +------------------------------------------------------------------------+
        |
        v
EC2 instance boots (Ubuntu 22.04, ~2-3 min to reach user_data)
        |
        v
user_data script runs automatically as root
  1. apt-get update && install curl, jq, unzip
  2. Install AWS CLI v2
  3. Fetch GitHub PAT from Secrets Manager (no plain-text secret anywhere)
  4. Read RunnerName tag from EC2 metadata service
  5. Download latest actions/runner binary from GitHub
  6. Install runner dependencies
  7. Write entrypoint.sh -> /usr/local/bin/github-runner-entrypoint.sh
  8. Write wrapper.sh   -> /usr/local/bin/github-runner-wrapper.sh
  9. Create systemd service: github-runner
 10. Start the service
        |
        v
github-runner-wrapper.sh runs (as actions-runner user)
  1. Calls entrypoint.sh:
     a. POST to GitHub API -> get short-lived registration token (1hr TTL)
     b. ./config.sh --ephemeral  -> registers runner for exactly ONE job
     c. ./run.sh                 -> waits for GitHub to assign the job, runs it
  2. After run.sh exits (regardless of exit code):
     aws ec2 terminate-instances --instance-ids <self>
        |
        v
EC2 instance terminates itself
        |
        v
GitHub fires workflow_job.completed webhook
        |
        v
Lambda 1 enqueues "completed" event to SQS
        |
        v
Lambda 2 decrements DynamoDB active_count
        |
        v
If more jobs are waiting in SQS: Lambda 2 processes the next one immediately
```

---

## Lambda 1 — Webhook Receiver (`index.py`)

**AWS Name:** `libp2p-runner-runner-webhook`
**Trigger:** API Gateway HTTP POST to `/webhook`
**Timeout:** 10 seconds
**File:** `lambda/index.py`

### What it does

This Lambda is the **front door**. GitHub calls it directly. Its only job is to:
1. Validate the request is genuinely from GitHub (HMAC check)
2. Decide if it's a job we care about (linux self-hosted, not windows)
3. Drop a message in SQS
4. Return HTTP 200 to GitHub **immediately**

It never launches EC2. It never touches DynamoDB. It is deliberately kept fast and simple.

### HMAC Signature Verification

GitHub signs every webhook payload with a shared secret using HMAC-SHA256:

```
GitHub sends:   X-Hub-Signature-256: sha256=abc123...
Lambda checks:  sha256=HMAC(WEBHOOK_SECRET, raw_request_body) == abc123...
```

If they don't match -> HTTP 401, message dropped. The `WEBHOOK_SECRET` is stored as a Lambda environment variable (set from `terraform.tfvars`, value `libp2p-runner`).

### Label Filtering

GitHub sends `workflow_job` events for **all jobs in the org**, including Windows jobs. This Lambda filters:

```python
WINDOWS_SKIP   = {"windows"}
LINUX_REQUIRED = {"self-hosted", "linux"}

def should_handle(labels):
    s = {l.lower() for l in labels}
    return not (s & WINDOWS_SKIP) and bool(s & LINUX_REQUIRED)
```

Jobs with `windows` in labels -> skipped with a log message, no EC2 launched.

### What it enqueues to SQS

For both `queued` and `completed` events:

```json
{
  "action":   "queued",
  "job_id":   73070312606,
  "job_name": "tox (3.10, interop)",
  "labels":   ["self-hosted", "linux", "x64"]
}
```

### Environment variables

| Variable | Value | Purpose |
|---|---|---|
| `WEBHOOK_SECRET` | `libp2p-runner` | HMAC key for signature verification |
| `JOB_QUEUE_URL` | SQS queue URL | Where to send messages |

---

## Lambda 2 — Job Processor (`processor.py`)

**AWS Name:** `libp2p-runner-runner-processor`
**Trigger:** SQS event source mapping (automatic, batch size = 1, batching window = 5s)
**Timeout:** 30 seconds
**File:** `lambda/processor.py`

### What triggers it

AWS automatically invokes this Lambda whenever a message appears in the SQS queue. You do not call it manually. The event source mapping polls SQS every 5 seconds and passes one message at a time to the Lambda.

### Pool management logic

```
On "queued" message:
  1. Read active_count from DynamoDB
  2. If active_count >= MAX_POOL_SIZE (5):
       -> raise Exception("pool-full-retry")
       -> SQS hides this message for 300 seconds (5 min)
       -> Lambda exits, SQS retries after 5 min
       -> Repeats until a slot opens up (job finishes and decrements counter)
  3. If active_count < MAX_POOL_SIZE:
       -> Atomically increment active_count
       -> Call EC2 RunInstances with the Launch Template
       -> Log the new instance ID

On "completed" message:
  1. Atomically decrement active_count (never below 0)
  2. Log the new count
  3. SQS automatically delivers the next queued job message
```

### Why raising an exception is the correct behaviour for pool-full

When the processor raises an exception, SQS treats the message as **failed**. SQS then:
1. Makes the message **invisible** for `visibility_timeout` seconds (300s = 5 min)
2. After 5 min, makes it **visible again** so the Lambda retries it
3. This repeats indefinitely — jobs are **never lost**, they just wait

### Environment variables

| Variable | Value | Purpose |
|---|---|---|
| `LAUNCH_TEMPLATE_ID` | `lt-0ccf22eb000f5d75c` | EC2 blueprint to use |
| `LAUNCH_TEMPLATE_VERSION` | `$Latest` | Always use latest version |
| `INSTANCE_TYPE` | `t3.micro` | EC2 instance type |
| `RUNNER_NAME_PREFIX` | `ec2-runner` | Prefix for runner names |
| `MAX_POOL_SIZE` | `5` | Max concurrent EC2 runners |
| `DYNAMODB_TABLE` | `libp2p-runner-runner-pool` | Pool state table name |

---

## Pool Management — DynamoDB Counter

**Table:** `libp2p-runner-runner-pool`
**Single row:** `pk = "pool"`, field `active_count`

```json
{ "pk": "pool", "active_count": 3 }
```

All increments and decrements use **DynamoDB atomic conditional updates** — safe for concurrent Lambda invocations:

```python
# Increment (no condition — just add 1)
table.update_item(
    UpdateExpression="ADD active_count :inc",
    ExpressionAttributeValues={":inc": 1}
)

# Decrement (conditional — never go below 0)
table.update_item(
    UpdateExpression="ADD active_count :dec",
    ConditionExpression="active_count > :zero",
    ExpressionAttributeValues={":dec": -1, ":zero": 0}
)
```

### Manual reset (if counter drifts from testing)

```bash
aws dynamodb update-item --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --key '{"pk":{"S":"pool"}}' \
  --update-expression "SET active_count = :zero" \
  --expression-attribute-values '{":zero":{"N":"0"}}'
```

---

## SQS Queue — The Backbone

**Queue:** `libp2p-runner-runner-jobs`
**DLQ:** `libp2p-runner-runner-dlq`

SQS is what makes the system **reliable**. Before SQS, the Lambda directly launched EC2 on every webhook — if it failed (pool full, vCPU limit, Lambda crash), the job was permanently lost.

With SQS:

| Scenario | What happens |
|---|---|
| Lambda crashes | SQS retries after `visibility_timeout` (300s) |
| Pool is full | Lambda raises exception -> SQS retries after 5 min |
| vCPU limit hit | Lambda raises exception -> SQS retries after 5 min |
| Message retention | 24 hours (matches GitHub's queued job TTL) |
| DLQ threshold | 1000 retries (job expires naturally at 24h before ever reaching DLQ) |

### Key settings

| Setting | Value | Reason |
|---|---|---|
| `visibility_timeout_seconds` | `300` (5 min) | Backoff when pool is full |
| `message_retention_seconds` | `86400` (24 hr) | Matches GitHub's job TTL |
| `maxReceiveCount` | `1000` | Never DLQ a pool-full retry |
| Batch size | `1` | One job processed per Lambda invocation |
| Batching window | `5s` | Small delay to reduce thundering-herd |

---

## EC2 Boot Sequence

When `processor.py` calls `ec2.run_instances()`, the instance boots and `user_data` runs automatically as root:

### Phase 1 — System setup (~2-3 min)
```bash
apt-get update && apt-get upgrade
apt-get install -y curl jq unzip
```

### Phase 2 — AWS CLI v2 install (~1 min)
```bash
curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip -o /tmp/awscliv2.zip
unzip + /tmp/aws/install
```

### Phase 3 — Fetch PAT from Secrets Manager (~2 sec)
```bash
ACCESS_TOKEN=$(aws secretsmanager get-secret-value \
  --region eu-north-1 \
  --secret-id '/test/1/github_pat' \
  --query SecretString --output text)
```
The IAM role attached to the instance grants this permission automatically.

### Phase 4 — Read runner name from EC2 tag (~1 sec)
```bash
INSTANCE_ID=$(curl http://169.254.169.254/latest/meta-data/instance-id)
RUNNER_NAME=$(aws ec2 describe-tags \
  --filters "Name=key,Values=RunnerName" \
  --query 'Tags[0].Value' --output text)
# e.g. "ec2-runner-73070312606"
```

### Phase 5 — Download GitHub Actions runner binary (~30 sec)
```bash
RUNNER_VERSION=$(curl https://api.github.com/repos/actions/runner/releases/latest | jq -r .tag_name)
curl https://github.com/actions/runner/releases/download/v${VERSION}/actions-runner-linux-x64-...tar.gz
```

### Phase 6 — Register and run (~30 sec)
The systemd service runs `github-runner-wrapper.sh`:
1. Calls `entrypoint.sh`:
   - POST to GitHub API -> short-lived registration token (1hr TTL)
   - `./config.sh --ephemeral` -> registers as a one-job runner
   - `./run.sh` -> waits for GitHub to assign the job, executes it
2. After `run.sh` exits (pass or fail):
   - `aws ec2 terminate-instances --instance-ids <self>`

> **Total boot time:** ~5-7 minutes. GitHub holds the job in "queued" state while waiting.

---

## Infrastructure Components Reference

| Resource | Terraform name | AWS name | Purpose |
|---|---|---|---|
| API Gateway | `aws_apigatewayv2_api.webhook` | `libp2p-runner-runner-webhook` | Public HTTPS endpoint for GitHub webhooks |
| Lambda (receiver) | `aws_lambda_function.webhook` | `libp2p-runner-runner-webhook` | Validates webhook, enqueues to SQS |
| Lambda (processor) | `aws_lambda_function.processor` | `libp2p-runner-runner-processor` | Pool logic, launches EC2 |
| SQS main queue | `aws_sqs_queue.runner_jobs` | `libp2p-runner-runner-jobs` | Durable job buffer |
| SQS DLQ | `aws_sqs_queue.runner_dlq` | `libp2p-runner-runner-dlq` | Only for truly broken messages |
| DynamoDB | `aws_dynamodb_table.runner_pool` | `libp2p-runner-runner-pool` | Atomic pool size counter |
| Launch Template | `aws_launch_template.runner` | `lt-0ccf22eb000f5d75c` | EC2 instance blueprint |
| Secrets Manager | `aws_secretsmanager_secret.github_pat` | `/test/1/github_pat` | GitHub PAT storage |
| IAM Role (EC2) | `aws_iam_role.runner` | `libp2p-runner-runner-role` | Lets EC2 read secret + self-terminate |
| IAM Role (Lambda) | `aws_iam_role.lambda` | `libp2p-runner-webhook-lambda-role` | Lets Lambda use SQS, DynamoDB, EC2 |

**Webhook URL:** `https://nxw9q3ngla.execute-api.eu-north-1.amazonaws.com/webhook`

---

## Issues Encountered & Root Causes

### Issue 1 — Jobs permanently lost after 3 SQS retries
**Symptom:** Jobs stuck waiting, no EC2 instances spinning up.
**Root cause:** `maxReceiveCount = 3` — when pool was full, SQS retried 3 times quickly then permanently moved jobs to the DLQ.
**Fix:** Raised `maxReceiveCount` to `1000` and `visibility_timeout` to `300s`. Jobs now retry every 5 minutes indefinitely until the pool has space.

### Issue 2 — `InvalidParameterCombination` on EC2 RunInstances
**Error:** `Network interfaces and an instance-level subnet ID may not be specified on the same request`
**Root cause:** Lambda was passing `SubnetId` + `SecurityGroupIds` directly, but the Launch Template's `network_interfaces` block already contains them.
**Fix:** Removed `SubnetId`/`SecurityGroupIds` from the Lambda's `run_instances()` call.

### Issue 3 — `NameError: verify_signature is not defined`
**Root cause:** A file edit accidentally deleted the `def verify_signature` line. File also had non-ASCII unicode characters corrupting it.
**Fix:** Deleted and recreated `lambda/index.py` cleanly.

### Issue 4 — `VcpuLimitExceeded`
**Error:** `You have requested more vCPU capacity than your current vCPU limit of 16`
**Root cause:** Default AWS quota is 16 vCPUs. `t3.micro` = 2 vCPUs. 10 stuck instances x 2 = 20 vCPUs.
**Fix:** Terminated stuck instances. Long-term: request vCPU limit increase at https://aws.amazon.com/contact-us/ec2-request

### Issue 5 — Instances not self-terminating
**Root cause:** Original `user_data` used a systemd `BindsTo` dependency that only fires when a unit is *stopped*, not when the process exits normally with code 0.
**Fix:** Replaced with `github-runner-wrapper.sh` — runs the runner then always calls `aws ec2 terminate-instances` regardless of exit code.

### Issue 6 — `user_data` silently not executing
**Root cause:** The `user_data` heredoc in Terraform had 4 spaces of indentation. Cloud-init requires `#!/bin/bash` at column 0.
**Fix:** Moved `user_data` to a separate `user_data.sh.tpl` file rendered with `templatefile()`.

---

## Debugging Cheatsheet

### Watch Lambda logs live
```bash
# Webhook receiver
aws logs tail /aws/lambda/libp2p-runner-runner-webhook \
  --region eu-north-1 --follow --format short

# Job processor
aws logs tail /aws/lambda/libp2p-runner-runner-processor \
  --region eu-north-1 --follow --format short
```

### Check pool state
```bash
aws dynamodb get-item --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --key '{"pk":{"S":"pool"}}' \
  --query 'Item.active_count.N' --output text
```

### Check SQS queue depths
```bash
aws sqs get-queue-attributes --region eu-north-1 \
  --queue-url $(terraform output -raw sqs_job_queue_url) \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

### Check running EC2 runners
```bash
aws ec2 describe-instances --region eu-north-1 \
  --filters "Name=tag:Role,Values=github-runner" \
            "Name=instance-state-name,Values=running,pending" \
  --query "Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key=='RunnerName']|[0].Value,State:State.Name}" \
  --output table
```

### Kill all runner instances + reset counter
```bash
aws ec2 terminate-instances --region eu-north-1 \
  --instance-ids $(aws ec2 describe-instances --region eu-north-1 \
    --filters "Name=tag:Role,Values=github-runner" \
              "Name=instance-state-name,Values=running,pending" \
    --query "Reservations[].Instances[].InstanceId" --output text)

aws dynamodb update-item --region eu-north-1 \
  --table-name libp2p-runner-runner-pool \
  --key '{"pk":{"S":"pool"}}' \
  --update-expression "SET active_count = :zero" \
  --expression-attribute-values '{":zero":{"N":"0"}}'
```

### SSH into a running runner instance
```bash
IP=$(aws ec2 describe-instances --region eu-north-1 \
  --filters "Name=tag:Role,Values=github-runner" \
            "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].PublicIpAddress" --output text)
ssh -i ~/.ssh/libp2p-runner.pem ubuntu@$IP
```

### Check logs on the instance
```bash
sudo tail -f /var/log/github-runner-init.log   # bootstrap / user_data log
sudo journalctl -u github-runner -f            # runner registration + job output
sudo systemctl status github-runner
```

### Redrive DLQ messages back to main queue
```bash
DLQ_ARN=$(aws sqs get-queue-attributes --region eu-north-1 \
  --queue-url $(terraform output -raw sqs_dlq_url) \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)
aws sqs start-message-move-task --region eu-north-1 --source-arn "$DLQ_ARN"
```

### Check vCPU quota
```bash
aws service-quotas get-service-quota \
  --region eu-north-1 \
  --service-code ec2 \
  --quota-code L-1216C47A
```
