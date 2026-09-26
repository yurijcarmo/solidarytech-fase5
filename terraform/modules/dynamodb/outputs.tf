output "table_name" {
  description = "DynamoDB transactions table name"
  value       = aws_dynamodb_table.transactions.name
}

output "table_arn" {
  description = "DynamoDB transactions table ARN"
  value       = aws_dynamodb_table.transactions.arn
}
