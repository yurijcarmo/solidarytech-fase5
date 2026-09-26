resource "aws_dynamodb_table" "transactions" {
  name         = "${var.project_name}-transactions"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "transaction_id"
  range_key    = "created_at"

  attribute {
    name = "transaction_id"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name        = "${var.project_name}-transactions"
    Project     = "SolidaryTech"
    Environment = var.environment
    CostCenter  = "NGO-Core"
    ManagedBy   = "Terraform"
    Service     = "donation-service"
  }
}
