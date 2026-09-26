#!/bin/bash
set -euo pipefail

# Local-only bootstrap. In AWS Academy, SQS and DynamoDB are provisioned by Terraform.

REGION="${AWS_DEFAULT_REGION:-us-east-1}"
MAIN_QUEUE="solidarytech-donations"
DLQ_QUEUE="solidarytech-donations-dlq"
TABLE="solidarytech-transactions"

echo "[localstack-init] creating SQS resources..."

DLQ_URL="$(awslocal sqs create-queue \
  --queue-name "$DLQ_QUEUE" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text)"

DLQ_ARN="$(awslocal sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names QueueArn \
  --region "$REGION" \
  --query 'Attributes.QueueArn' \
  --output text)"

MAIN_QUEUE_URL="$(awslocal sqs create-queue \
  --queue-name "$MAIN_QUEUE" \
  --region "$REGION" \
  --query 'QueueUrl' \
  --output text)"

# RedrivePolicy is JSON serialized as a string inside the attributes object.
cat > /tmp/sqs-redrive-attributes.json <<EOF
{
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"${DLQ_ARN}\",\"maxReceiveCount\":\"3\"}"
}
EOF

awslocal sqs set-queue-attributes \
  --queue-url "$MAIN_QUEUE_URL" \
  --attributes file:///tmp/sqs-redrive-attributes.json \
  --region "$REGION"

echo "[localstack-init] creating DynamoDB table..."

if ! awslocal dynamodb describe-table \
  --table-name "$TABLE" \
  --region "$REGION" \
  >/dev/null 2>&1; then

  awslocal dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions \
      AttributeName=transaction_id,AttributeType=S \
      AttributeName=created_at,AttributeType=S \
    --key-schema \
      AttributeName=transaction_id,KeyType=HASH \
      AttributeName=created_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    >/dev/null
fi

echo "[localstack-init] local AWS environment ready."