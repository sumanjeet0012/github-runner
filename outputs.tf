# ─────────────────────────────────────────
# Ubuntu outputs
# ─────────────────────────────────────────

output "ubuntu_instance_ids" {
  description = "Instance IDs of all Ubuntu instances"
  value       = aws_instance.ubuntu[*].id
}

output "ubuntu_public_ips" {
  description = "Public IP addresses of Ubuntu instances (if assigned)"
  value       = aws_instance.ubuntu[*].public_ip
}

output "ubuntu_private_ips" {
  description = "Private IP addresses of Ubuntu instances"
  value       = aws_instance.ubuntu[*].private_ip
}

output "ubuntu_ami_id" {
  description = "AMI ID used for Ubuntu instances"
  value       = data.aws_ami.ubuntu.id
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
