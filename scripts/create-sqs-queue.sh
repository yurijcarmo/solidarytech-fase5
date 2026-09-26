#!/bin/bash
set -e
source "$(dirname "$0")/lib/logging.sh"

echo "Creating SQS queues in LocalStack..."

aws --endpoint-url=http://localhost:4566 sqs create-queue \
    --queue-name solidarytech-donations-dlq \
    --region us-east-1

DLQ_ARN=$(aws --endpoint-url=http://localhost:4566 sqs get-queue-attributes \
    --queue-url http://localhost:4566/000000000000/solidarytech-donations-dlq \
    --attribute-names QueueArn \
    --region us-east-1 \
    --query 'Attributes.QueueArn' --output text)

aws --endpoint-url=http://localhost:4566 sqs create-queue \
    --queue-name solidarytech-donations \
    --attributes "{\"RedrivePolicy\":\"{\\\"deadLetterTargetArn\\\":\\\"${DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\"}" \
    --region us-east-1

echo "SQS queues created successfully!"
echo "Main queue: http://localhost:4566/000000000000/solidarytech-donations"
echo "DLQ: http://localhost:4566/000000000000/solidarytech-donations-dlq"

echo ""
echo "Creating DynamoDB table in LocalStack..."

aws --endpoint-url=http://localhost:4566 dynamodb create-table \
    --table-name solidarytech-transactions \
    --attribute-definitions \
        AttributeName=transaction_id,AttributeType=S \
        AttributeName=created_at,AttributeType=S \
    --key-schema \
        AttributeName=transaction_id,KeyType=HASH \
        AttributeName=created_at,KeyType=RANGE \
    --billing-mode PAY_PER_REQUEST \
    --region us-east-1

echo "DynamoDB table 'solidarytech-transactions' created successfully!"
