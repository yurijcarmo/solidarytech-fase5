# --- Dead Letter Queue ---

resource "aws_sqs_queue" "donations_dlq" {
  name                       = "${var.project_name}-donations-dlq"
  message_retention_seconds  = 1209600 # 14 days
  visibility_timeout_seconds = 60
  sqs_managed_sse_enabled    = true

  tags = {
    Name    = "${var.project_name}-donations-dlq"
    Service = "donation-service"
    Type    = "dead-letter-queue"
  }
}

# --- Main Donations Queue ---

resource "aws_sqs_queue" "donations" {
  name                       = "${var.project_name}-donations"
  delay_seconds              = 0
  max_message_size           = 262144
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 10
  visibility_timeout_seconds = 30
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.donations_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name    = "${var.project_name}-donations"
    Service = "donation-service"
    Type    = "main-queue"
  }
}

# --- CloudWatch Alarms for queue monitoring ---

resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  alarm_name          = "${var.project_name}-donations-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Sum"
  threshold           = 0
  alarm_description   = "Alert when messages land in the donations DLQ"

  dimensions = {
    QueueName = aws_sqs_queue.donations_dlq.name
  }

  tags = {
    Name    = "${var.project_name}-dlq-alarm"
    Service = "donation-service"
  }
}
