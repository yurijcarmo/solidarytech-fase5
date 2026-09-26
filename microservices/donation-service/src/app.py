import json
import logging
import math
import os
import time
import uuid
from datetime import datetime, timezone
import boto3
import redis
from flask import Flask, jsonify, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Histogram, make_wsgi_app
from werkzeug.middleware.dispatcher import DispatcherMiddleware

from models import Donation, db

SERVICE_NAME = os.getenv("SERVICE_NAME", "donation-service")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(SERVICE_NAME)

CURRENCY_RATES = {
    "BRL": 1.0,
    "USD": 5.45,
    "EUR": 5.95,
    "GBP": 6.85,
    "JPY": 0.037,
}
SUPPORTED_CURRENCIES = list(CURRENCY_RATES.keys())

DONATION_DURATION = Histogram(
    "donation_request_duration_seconds",
    "Time spent processing donation requests",
    ["method", "endpoint", "status"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0],
)
DONATION_ERRORS = Counter(
    "donation_errors_total",
    "Total donation processing errors",
    ["error_type"],
)
DONATION_PROCESSED = Counter(
    "donation_processed_total",
    "Total donations processed successfully",
)
DONATION_SLO_LATENCY = Histogram(
    "donation_slo_latency_seconds",
    "Donation processing latency for SLO calculation",
    buckets=[0.1, 0.25, 0.5, 1.0, 2.0],
)
DONATION_BY_CURRENCY = Counter(
    "donation_by_currency_total",
    "Donations received by original currency",
    ["currency"],
)
DONATION_AMOUNT_BRL = Counter(
    "donation_amount_brl_total",
    "Total donation amount received in BRL",
)

request_timestamps = []
error_count = 0
total_count = 0


def setup_telemetry(app):
    resource = Resource.create({"service.name": SERVICE_NAME})
    provider = TracerProvider(resource=resource)
    otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "localhost:4317")
    try:
        exporter = OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)
        provider.add_span_processor(BatchSpanProcessor(exporter))
    except Exception:
        logger.warning("OTLP exporter unavailable, tracing disabled")
    trace.set_tracer_provider(provider)
    FlaskInstrumentor().instrument_app(app)


def get_sqs_client():
    region = os.getenv("AWS_REGION", "us-east-1")
    endpoint_url = os.getenv("AWS_ENDPOINT_URL")
    kwargs = {"region_name": region}
    if endpoint_url:
        kwargs["endpoint_url"] = endpoint_url
    return boto3.client("sqs", **kwargs)


def get_dynamodb_resource():
    region = os.getenv("AWS_REGION", "us-east-1")
    endpoint_url = os.getenv("DYNAMODB_ENDPOINT")
    kwargs = {"region_name": region}
    if endpoint_url:
        kwargs["endpoint_url"] = endpoint_url
    return boto3.resource("dynamodb", **kwargs)


def get_redis_client():
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    try:
        client = redis.from_url(redis_url, decode_responses=True)
        client.ping()
        return client
    except Exception:
        logger.warning("Redis unavailable, caching disabled")
        return None


def write_audit_log(dynamo_table, donation, transaction_id, original_currency, original_amount, converted_amount):
    try:
        dynamo_table.put_item(Item={
            "transaction_id": transaction_id,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "donation_id": donation.id,
            "donor_name": donation.donor_name,
            "donor_email": donation.donor_email,
            "ngo_id": donation.ngo_id,
            "original_currency": original_currency,
            "original_amount": str(original_amount),
            "converted_currency": "BRL",
            "converted_amount": str(converted_amount),
            "payment_method": donation.payment_method,
            "status": donation.status,
            "event": "DONATION_CREATED",
        })
    except Exception as e:
        logger.error("Failed to write DynamoDB audit log: %s", e)


def create_app():
    app = Flask(__name__)
    database_url = os.environ.get("DATABASE_URL", "")
    if not database_url:
        raise RuntimeError("DATABASE_URL environment variable is required")
    app.config["SQLALCHEMY_DATABASE_URI"] = database_url
    app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False

    db.init_app(app)
    setup_telemetry(app)
    app.wsgi_app = DispatcherMiddleware(app.wsgi_app, {"/metrics": make_wsgi_app()})

    with app.app_context():
        for attempt in range(10):
            try:
                db.create_all()
                break
            except Exception as e:
                logger.warning("DB not ready (attempt %d/10): %s", attempt + 1, e)
                time.sleep(3)
        else:
            logger.error("Failed to connect to database after 10 attempts")

    tracer = trace.get_tracer(SERVICE_NAME)
    sqs_queue_url = os.getenv("SQS_QUEUE_URL", "")
    dynamo_table_name = os.getenv("DYNAMODB_TABLE_NAME", "solidarytech-transactions")

    redis_client = get_redis_client()

    dynamo_table = None
    try:
        dynamo = get_dynamodb_resource()
        dynamo_table = dynamo.Table(dynamo_table_name)
    except Exception:
        logger.warning("DynamoDB unavailable, audit logging disabled")

    @app.route("/health")
    def health():
        return jsonify({"status": "healthy", "service": SERVICE_NAME})

    @app.route("/region")
    def region():
        region = os.getenv("AWS_REGION", "unknown")
        cluster = os.getenv("CLUSTER_NAME", "unknown")
        return jsonify({
            "region": region,
            "cluster": cluster,
            "service": SERVICE_NAME,
            "role": "dr" if "dr" in cluster.lower() or region == "us-west-2" else "production",
        })

    @app.route("/ready")
    def ready():
        try:
            db.session.execute(db.text("SELECT 1"))
            return jsonify({"status": "ready"})
        except Exception:
            return jsonify({"status": "not_ready"}), 503

    @app.route("/api/v1/donations/currencies", methods=["GET"])
    def list_currencies():
        with tracer.start_as_current_span("list_currencies"):
            if redis_client:
                cached = redis_client.get("currencies:rates")
                if cached:
                    return jsonify(json.loads(cached))

            result = {
                "supported_currencies": SUPPORTED_CURRENCIES,
                "base_currency": "BRL",
                "rates": {k: {"to_brl": v, "description": _currency_name(k)} for k, v in CURRENCY_RATES.items()},
                "example": "Para doar 100 USD, o valor convertido sera 100 * 5.45 = 545.00 BRL",
            }

            if redis_client:
                redis_client.setex("currencies:rates", 60, json.dumps(result))

            return jsonify(result)

    @app.route("/api/v1/donations", methods=["GET"])
    def list_donations():
        with tracer.start_as_current_span("list_donations"):
            page = request.args.get("page", 1, type=int)
            per_page = min(request.args.get("per_page", 20, type=int), 100)
            pagination = Donation.query.order_by(
                Donation.created_at.desc()
            ).paginate(page=page, per_page=per_page, error_out=False)
            return jsonify({
                "data": [d.to_dict() for d in pagination.items],
                "total": pagination.total,
                "page": page,
                "pages": pagination.pages,
            })

    @app.route("/api/v1/donations/<int:donation_id>", methods=["GET"])
    def get_donation(donation_id):
        with tracer.start_as_current_span("get_donation", attributes={"donation.id": donation_id}):
            donation = db.session.get(Donation, donation_id)
            if not donation:
                return jsonify({"error": "Donation not found"}), 404
            return jsonify(donation.to_dict())

    @app.route("/api/v1/donations", methods=["POST"])
    def create_donation():
        global error_count, total_count
        start_time = time.time()
        with tracer.start_as_current_span("create_donation") as span:
            data = request.get_json()
            if not data or not data.get("donor_name") or not data.get("amount") or not data.get("payment_method"):
                DONATION_ERRORS.labels(error_type="validation").inc()
                error_count += 1
                total_count += 1
                return jsonify({"error": "donor_name, amount, and payment_method are required"}), 400

            original_currency = data.get("currency", "BRL").upper()
            if original_currency not in SUPPORTED_CURRENCIES:
                DONATION_ERRORS.labels(error_type="invalid_currency").inc()
                error_count += 1
                total_count += 1
                return jsonify({
                    "error": f"Unsupported currency: {original_currency}. "
                             f"Supported: {SUPPORTED_CURRENCIES}"
                }), 400

            try:
                original_amount = float(data["amount"])
            except (ValueError, TypeError):
                DONATION_ERRORS.labels(error_type="validation").inc()
                error_count += 1
                total_count += 1
                return jsonify({"error": "Invalid amount value"}), 400
            if original_amount <= 0 or math.isnan(original_amount) or math.isinf(original_amount):
                DONATION_ERRORS.labels(error_type="validation").inc()
                error_count += 1
                total_count += 1
                return jsonify({"error": "Amount must be a positive finite number"}), 400
            conversion_rate = CURRENCY_RATES[original_currency]
            amount_brl = round(original_amount * conversion_rate, 2)

            transaction_id = str(uuid.uuid4())
            span.set_attribute("donation.transaction_id", transaction_id)
            span.set_attribute("donation.original_amount", original_amount)
            span.set_attribute("donation.original_currency", original_currency)
            span.set_attribute("donation.amount_brl", amount_brl)

            donation = Donation(
                donor_name=data["donor_name"],
                donor_email=data.get("donor_email", ""),
                ngo_id=data.get("ngo_id", 0),
                amount=amount_brl,
                original_amount=original_amount,
                original_currency=original_currency,
                currency="BRL",
                payment_method=data["payment_method"],
                status="pending",
                transaction_id=transaction_id,
            )
            db.session.add(donation)
            db.session.commit()

            DONATION_BY_CURRENCY.labels(currency=original_currency).inc()
            DONATION_AMOUNT_BRL.inc(amount_brl)

            if dynamo_table:
                write_audit_log(dynamo_table, donation, transaction_id, original_currency, original_amount, amount_brl)

            if sqs_queue_url:
                try:
                    sqs = get_sqs_client()
                    sqs.send_message(
                        QueueUrl=sqs_queue_url,
                        MessageBody=json.dumps({
                            "donation_id": donation.id,
                            "transaction_id": transaction_id,
                            "amount": amount_brl,
                            "original_amount": original_amount,
                            "original_currency": original_currency,
                            "ngo_id": donation.ngo_id,
                        }),
                    )
                    span.add_event("message_sent_to_sqs")
                except Exception as e:
                    logger.error("Failed to send to SQS: %s", e)
                    DONATION_ERRORS.labels(error_type="sqs_publish").inc()

            if redis_client:
                redis_client.delete("donations:stats")

            duration = time.time() - start_time
            DONATION_DURATION.labels(method="POST", endpoint="/api/v1/donations", status="201").observe(duration)
            DONATION_SLO_LATENCY.observe(duration)
            DONATION_PROCESSED.inc()
            total_count += 1
            request_timestamps.append(time.time())

            logger.info("Donation created: id=%d tx=%s original=%.2f %s converted=%.2f BRL",
                        donation.id, transaction_id, original_amount, original_currency, amount_brl)
            return jsonify(donation.to_dict()), 201

    @app.route("/api/v1/donations/stats", methods=["GET"])
    def donation_stats():
        with tracer.start_as_current_span("donation_stats"):
            if redis_client:
                cached = redis_client.get("donations:stats")
                if cached:
                    return jsonify(json.loads(cached))

            total = db.session.query(db.func.count(Donation.id)).scalar() or 0
            total_brl = float(db.session.query(
                db.func.coalesce(db.func.sum(Donation.amount), 0)
            ).scalar())
            completed = db.session.query(
                db.func.count(Donation.id)
            ).filter(Donation.status == "completed").scalar() or 0

            result = {
                "total_donations": total,
                "completed_donations": completed,
                "total_amount_brl": round(total_brl, 2),
                "success_rate": round(completed / total * 100, 2) if total > 0 else 0,
            }

            if redis_client:
                redis_client.setex("donations:stats", 60, json.dumps(result))

            return jsonify(result)

    @app.route("/api/v1/donations/metrics/golden", methods=["GET"])
    def golden_metrics():
        with tracer.start_as_current_span("golden_metrics"):
            now = time.time()
            recent = [t for t in request_timestamps if now - t < 300]
            throughput = len(recent) / 300.0 if recent else 0
            error_rate = (error_count / total_count * 100) if total_count > 0 else 0

            return jsonify({
                "golden_metrics": {
                    "throughput_rps": round(throughput, 4),
                    "error_rate_percent": round(error_rate, 2),
                    "total_requests": total_count,
                    "total_errors": error_count,
                },
                "slo": {
                    "latency_target_ms": 500,
                    "availability_target_percent": 99.9,
                    "error_budget_percent": 0.1,
                },
            })

    return app


def _currency_name(code):
    names = {
        "BRL": "Real Brasileiro", "USD": "Dolar Americano",
        "EUR": "Euro", "GBP": "Libra Esterlina", "JPY": "Iene Japones",
    }
    return names.get(code, code)


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8081)
