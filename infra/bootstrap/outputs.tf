output "state_bucket" {
  description = "S3 bucket holding the cluster stack's Terraform state."
  value       = aws_s3_bucket.state.bucket
}

output "region" {
  value = var.region
}

output "tls_backup_secret_arn" {
  value = aws_secretsmanager_secret.tls_backup.arn
}
