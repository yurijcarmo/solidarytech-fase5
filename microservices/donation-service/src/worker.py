import json
import logging
import os
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import boto3
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.propagate import extract
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from models import Donation
from payment_gateway import authorize_payment

SERVICE_NAME = os.getenv("SERVICE_NAME", "donation-worker")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(SERVICE_NAME)

WORKER_MESSAGES = Counter(
    "donation_worker_messages_total",
    "Total SQS donation messages handled by the worker",
    ["result"],
)
WORKER_PROCESSING_DURATION = Histogram(
    "donation_worker_processing_duration_seconds",
    "Time spent processing donation messages",
    buckets=[0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0, 10.0],
)
WORKER_POLL_ERRORS = Counter(
    "donation_worker_poll_errors_total",
    "Total errors while polling SQS",
)
WORKER_MESSAGES_IN_PROGRESS = Gauge(
    "donation_worker_messages_in_progress",
    "Number of donation messages currently being processed",
)
WORKER_LAST_SUCCESSFUL_POLL = Gauge(
    "donation_worker_last_successful_poll_timestamp_seconds",
    "Unix timestamp of the last successful SQS poll",
)


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


class WorkerStatusHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            payload = json.dumps({"status": "healthy", "service": SERVICE_NAME}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        if self.path == "/metrics":
            payload = generate_latest()
            self.send_response(200)
            self.send_header("Content-Type", CONTENT_TYPE_LATEST)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return

        self.send_response(404)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


def start_status_server():
    port = int(os.getenv("WORKER_METRICS_PORT", "8091"))
    server = ThreadingHTTPServer(("0.0.0.0", port), WorkerStatusHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    logger.info("Worker health and metrics server listening on port %d", port)


def process_donation(session, tracer, message_body, dynamo_table=None):
    data = json.loads(message_body)
    parent_context = extract(data.get("trace_context") or {})

    with tracer.start_as_current_span("process_donation", context=parent_context) as span:
        donation_id = data["donation_id"]
        transaction_id = data["transaction_id"]
        span.set_attribute("donation.id", donation_id)
        span.set_attribute("donation.transaction_id", transaction_id)

        donation = session.query(Donation).filter_by(id=donation_id).first()
        if not donation:
            raise LookupError(f"Donation {donation_id} not found")

        donation.status = "processing"
        session.commit()

        currency = data.get("original_currency", "BRL")
        payment_result = authorize_payment(data["amount"], currency, donation.payment_method)
        span.set_attribute("payment.status", payment_result["status"])

        if payment_result["approved"]:
            donation.status = "completed"
            donation.processed_at = datetime.now(timezone.utc)
            logger.info("Donation %d completed, tx=%s", donation_id, transaction_id)
        else:
            donation.status = "failed"
            logger.warning("Donation %d failed, tx=%s reason=%s", donation_id, transaction_id, payment_result["status"])
            span.set_attribute("error", True)

        audit_created_at = data.get("audit_created_at")
        if dynamo_table and audit_created_at:
            try:
                dynamo_table.update_item(
                    Key={"transaction_id": transaction_id, "created_at": audit_created_at},
                    UpdateExpression=(
                        "SET #s = :s, payment_status = :ps, authorization_code = :ac, "
                        "processed_at = :pa, #e = :e"
                    ),
                    ExpressionAttributeNames={"#s": "status", "#e": "event"},
                    ExpressionAttributeValues={
                        ":s": donation.status,
                        ":ps": payment_result["status"],
                        ":ac": payment_result.get("authorization_code") or "N/A",
                        ":pa": datetime.now(timezone.utc).isoformat(),
                        ":e": "DONATION_PROCESSED",
                    },
                )
            except Exception as exc:
                logger.error("Failed to update DynamoDB audit for tx=%s: %s", transaction_id, exc)

        session.commit()
        return donation.status


def main():
    tracer = setup_telemetry()
    start_status_server()

    database_url = os.environ.get("DATABASE_URL", "")
    if not database_url:
        raise RuntimeError("DATABASE_URL environment variable is required")
    engine = create_engine(database_url, pool_pre_ping=True)
    Session = sessionmaker(bind=engine)

    sqs_queue_url = os.getenv("SQS_QUEUE_URL", "")
    if not sqs_queue_url:
        raise RuntimeError("SQS_QUEUE_URL environment variable is required")

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
            WORKER_LAST_SUCCESSFUL_POLL.set_to_current_time()

            for msg in response.get("Messages", []):
                session = Session()
                started_at = time.perf_counter()
                WORKER_MESSAGES_IN_PROGRESS.inc()
                try:
                    result = process_donation(session, tracer, msg["Body"], dynamo_table)
                    sqs.delete_message(QueueUrl=sqs_queue_url, ReceiptHandle=msg["ReceiptHandle"])
                    WORKER_MESSAGES.labels(result=result).inc()
                except Exception:
                    session.rollback()
                    WORKER_MESSAGES.labels(result="error").inc()
                    logger.exception("Error processing donation message; message will be retried by SQS")
                finally:
                    WORKER_PROCESSING_DURATION.observe(time.perf_counter() - started_at)
                    WORKER_MESSAGES_IN_PROGRESS.dec()
                    session.close()
        except Exception:
            WORKER_POLL_ERRORS.inc()
            logger.exception("Error polling SQS")
            time.sleep(5)


if __name__ == "__main__":
    main()
