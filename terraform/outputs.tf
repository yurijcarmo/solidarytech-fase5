output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "eks_cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_certificate_authority" {
  description = "EKS cluster CA certificate"
  value       = module.eks.cluster_certificate_authority
  sensitive   = true
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = module.rds.endpoint
}

output "rds_port" {
  description = "RDS PostgreSQL port"
  value       = module.rds.port
}

output "sqs_donations_queue_url" {
  description = "SQS donations queue URL"
  value       = module.sqs.donations_queue_url
}

output "sqs_donations_dlq_url" {
  description = "SQS donations DLQ URL"
  value       = module.sqs.donations_dlq_url
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for each service"
  value       = module.ecr.repository_urls
}

output "s3_backup_bucket" {
  description = "S3 backup bucket name"
  value       = module.s3.backup_bucket_name
}

output "dynamodb_table_name" {
  description = "DynamoDB transactions table name"
  value       = module.dynamodb.table_name
}

output "redis_endpoint" {
  description = "ElastiCache Redis endpoint"
  value       = module.elasticache.redis_endpoint
}

output "redis_url" {
  description = "Redis connection URL"
  value       = module.elasticache.redis_url
}
