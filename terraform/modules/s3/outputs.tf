output "backup_bucket_name" {
  description = "Backup S3 bucket name"
  value       = aws_s3_bucket.backup.id
}

output "backup_bucket_arn" {
  description = "Backup S3 bucket ARN"
  value       = aws_s3_bucket.backup.arn
}
