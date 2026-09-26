output "endpoint" {
  description = "RDS instance endpoint"
  value       = var.is_read_replica ? aws_db_instance.replica[0].address : aws_db_instance.main[0].address
}

output "port" {
  description = "RDS instance port"
  value       = var.is_read_replica ? aws_db_instance.replica[0].port : aws_db_instance.main[0].port
}

output "db_name" {
  description = "Database name"
  value       = var.is_read_replica ? "" : aws_db_instance.main[0].db_name
}

output "security_group_id" {
  description = "RDS security group ID"
  value       = aws_security_group.rds.id
}

output "instance_id" {
  description = "RDS instance identifier"
  value       = var.is_read_replica ? aws_db_instance.replica[0].id : aws_db_instance.main[0].id
}

output "arn" {
  description = "RDS instance ARN"
  value       = var.is_read_replica ? aws_db_instance.replica[0].arn : aws_db_instance.main[0].arn
}
