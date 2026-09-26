import json
import logging
import os
import time
from datetime import datetime, timezone

import boto3
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from models import Donation
from payment_gateway import authorize_payment

SERVICE_NAME = os.getenv("SERVICE_NAME", "donation-worker")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(SERVICE_NAME)


def setup_telemetry():
    resource = Resource.create({"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
    try:
        exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    except Exception:
        logger.warning("OTLP exporter unavailable, tracing disabled")
    trace.set_tracer_provider(provider)
    return trace.get_tracer(SERVICE_NAME)


def process_donation(session, tracer, message_body, dynamo_table=None):
    with tracer.start_as_current_span("process_donation") as span:
        data = json.loads(message_body)
        donation_id = data["donation_id"]
        span.set_attribute("donation.id", donation_id)
        span.set_attribute("donation.amount", data["amount"])

        donation = session.query(Donation).filter_by(id=donation_id).first()
        if not donation:
            logger.error("Donation %d not found", donation_id)
            span.set_attribute("error", True)
            return

        donation.status = "processing"
        session.commit()

        currency = data.get("original_currency", "BRL")
        payment_result = authorize_payment(data["amount"], currency, donation.payment_method)
        span.set_attribute("payment.status", payment_result["status"])
        span.set_attribute("payment.authorization_code", payment_result.get("authorization_code") or "")

        if payment_result["approved"]:
            donation.status = "completed"
            donation.processed_at = datetime.now(timezone.utc)
            logger.info("Donation %d completed, tx=%s auth=%s",
                        donation_id, data["transaction_id"], payment_result["authorization_code"])
        else:
            donation.status = "failed"
            logger.warning("Donation %d failed, tx=%s reason=%s",
                           donation_id, data["transaction_id"], payment_result["status"])
            span.set_attribute("error", True)

        if dynamo_table:
            try:
                dynamo_table.update_item(
                    Key={"transaction_id": data["transaction_id"], "created_at": donation.created_at.isoformat()},
                    UpdateExpression="SET #s = :s, payment_status = :ps, authorization_code = :ac, processed_at = :pa",
                    ExpressionAttributeNames={"#s": "status"},
                    ExpressionAttributeValues={
                        ":s": donation.status,
                        ":ps": payment_result["status"],
                        ":ac": payment_result.get("authorization_code") or "N/A",
                        ":pa": datetime.now(timezone.utc).isoformat(),
                    },
                )
            except Exception as e:
                logger.error("Failed to update DynamoDB audit: %s", e)

        session.commit()


def main():
    tracer = setup_telemetry()
    database_url = os.environ.get("DATABASE_URL", "")
    if not database_url:
        raise RuntimeError("DATABASE_URL environment variable is required")
    engine = create_engine(database_url)
    Session = sessionmaker(bind=engine)

    sqs_queue_url = os.getenv("SQS_QUEUE_URL", "")
    region = os.getenv("AWS_REGION", "us-east-1")
    endpoint_url = os.getenv("AWS_ENDPOINT_URL")

    kwargs = {"region_name": region}
    if endpoint_url:
        kwargs["endpoint_url"] = endpoint_url
    sqs = boto3.client("sqs", **kwargs)

    dynamo_table = None
    dynamo_table_name = os.getenv("DYNAMODB_TABLE_NAME", "solidarytech-transactions")
    dynamo_endpoint = os.getenv("DYNAMODB_ENDPOINT")
    try:
        dkw = {"region_name": region}
        if dynamo_endpoint:
            dkw["endpoint_url"] = dynamo_endpoint
        dynamo = boto3.resource("dynamodb", **dkw)
        dynamo_table = dynamo.Table(dynamo_table_name)
    except Exception:
        logger.warning("DynamoDB unavailable in worker, audit updates disabled")

    logger.info("Worker started, polling SQS queue: %s", sqs_queue_url)

    while True:
        try:
            response = sqs.receive_message(
                QueueUrl=sqs_queue_url,
                MaxNumberOfMessages=10,
                WaitTimeSeconds=20,
            )
            messages = response.get("Messages", [])
            for msg in messages:
                session = Session()
                try:
                    process_donation(session, tracer, msg["Body"], dynamo_table)
                    sqs.delete_message(QueueUrl=sqs_queue_url, ReceiptHandle=msg["ReceiptHandle"])
                except Exception:
                    logger.exception("Error processing message")
                finally:
                    session.close()
        except Exception:
            logger.exception("Error polling SQS")
            time.sleep(5)


if __name__ == "__main__":
    main()
