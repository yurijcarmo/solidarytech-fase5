output "donations_queue_url" {
  description = "Donations SQS queue URL"
  value       = aws_sqs_queue.donations.url
}

output "donations_queue_arn" {
  description = "Donations SQS queue ARN"
  value       = aws_sqs_queue.donations.arn
}

output "donations_dlq_url" {
  description = "Donations DLQ URL"
  value       = aws_sqs_queue.donations_dlq.url
}

output "donations_dlq_arn" {
  description = "Donations DLQ ARN"
  value       = aws_sqs_queue.donations_dlq.arn
}
