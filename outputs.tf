# ─────────────────────────────────────────
# Networking (read-only data sources)
# ─────────────────────────────────────────

output "vpc_id" {
  description = "VPC where runner instances are launched"
  value       = data.aws_vpc.main.id
}

output "subnet_id" {
  description = "Subnet where runner instances are launched"
  value       = data.aws_subnet.main.id
}

output "internet_gateway_id" {
  description = "Internet Gateway attached to the VPC (confirms outbound internet access)"
  value       = data.aws_internet_gateway.main.id
}

# ─────────────────────────────────────────
# Ephemeral runner infrastructure
# ─────────────────────────────────────────

output "runner_launch_template_id" {
  description = "ID of the EC2 Launch Template used to spin up ephemeral Linux runners"
  value       = aws_launch_template.runner.id
}

output "runner_launch_template_id_windows" {
  description = "ID of the EC2 Launch Template used to spin up ephemeral Windows runners"
  value       = aws_launch_template.runner_windows.id
}

output "ubuntu_ami_id" {
  description = "AMI ID used for Ubuntu runner instances"
  value       = data.aws_ami.ubuntu.id
}

output "webhook_url" {
  description = "GitHub webhook URL - register this in your org/repo webhook settings (POST, application/json, workflow_job events)"
  value       = "${aws_apigatewayv2_stage.webhook.invoke_url}webhook"
}

output "sqs_job_queue_url" {
  description = "SQS queue URL that buffers pending runner jobs"
  value       = aws_sqs_queue.runner_jobs.url
}

output "sqs_dlq_url" {
  description = "Dead-letter queue URL - inspect failed jobs here"
  value       = aws_sqs_queue.runner_dlq.url
}

output "dynamodb_pool_table" {
  description = "DynamoDB table tracking active runner count"
  value       = aws_dynamodb_table.runner_pool.name
}

# ─────────────────────────────────────────
# Windows outputs
# ─────────────────────────────────────────

output "windows_instance_ids" {
  description = "Instance IDs of all Windows instances"
  value       = aws_instance.windows[*].id
}

output "windows_public_ips" {
  description = "Public IP addresses of Windows instances (if assigned)"
  value       = aws_instance.windows[*].public_ip
}

output "windows_private_ips" {
  description = "Private IP addresses of Windows instances"
  value       = aws_instance.windows[*].private_ip
}

output "windows_ami_id" {
  description = "AMI ID used for Windows instances"
  value       = data.aws_ami.windows.id
}

output "windows_password_data" {
  description = "Encrypted password data for Windows instances (decrypt with your private key)"
  value       = aws_instance.windows[*].password_data
  sensitive   = true
}

# ─────────────────────────────────────────
# Security Group
# ─────────────────────────────────────────

output "security_group_id" {
  description = "ID of the shared security group"
  value       = aws_security_group.instances.id
}

# ─────────────────────────────────────────
# GitHub PAT secret
# ─────────────────────────────────────────

output "github_pat_secret_arn" {
  description = "ARN of the AWS Secrets Manager secret holding the GitHub PAT"
  value       = aws_secretsmanager_secret.github_pat.arn
}

output "github_pat_secret_name" {
  description = "Name of the AWS Secrets Manager secret holding the GitHub PAT"
  value       = aws_secretsmanager_secret.github_pat.name
}
