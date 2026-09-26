import json
import logging
import os
import time

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

from models import NGO, db

NGO_REQUEST_DURATION = Histogram(
    "ngo_request_duration_seconds",
    "Time spent processing NGO requests",
    ["method", "endpoint", "status"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
NGO_ERRORS = Counter(
    "ngo_errors_total",
    "Total NGO processing errors",
    ["error_type"],
)
NGO_OPERATIONS = Counter(
    "ngo_operations_total",
    "Total NGO operations by type",
    ["operation"],
)

SERVICE_NAME = os.getenv("SERVICE_NAME", "ngo-service")

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
logger = logging.getLogger(SERVICE_NAME)


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

    redis_client = None
    redis_url = os.getenv("REDIS_URL", "redis://localhost:6379/0")
    try:
        redis_client = redis.from_url(redis_url, decode_responses=True)
        redis_client.ping()
        logger.info("Redis connected for caching")
    except Exception:
        logger.warning("Redis unavailable, caching disabled")
        redis_client = None

    def _invalidate_cache():
        if redis_client:
            redis_client.delete("ngos:list")
            keys = redis_client.keys("ngos:*")
            if keys:
                redis_client.delete(*keys)

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

    @app.route("/api/v1/ngos", methods=["GET"])
    def list_ngos():
        start_time = time.time()
        with tracer.start_as_current_span("list_ngos"):
            page = request.args.get("page", 1, type=int)
            per_page = min(request.args.get("per_page", 20, type=int), 100)
            cache_key = f"ngos:list:p{page}:pp{per_page}"

            if redis_client:
                cached = redis_client.get(cache_key)
                if cached:
                    duration = time.time() - start_time
                    NGO_REQUEST_DURATION.labels(
                        method="GET", endpoint="/api/v1/ngos", status="200"
                    ).observe(duration)
                    return jsonify(json.loads(cached))

            query = NGO.query.filter_by(active=True)
            pagination = query.paginate(page=page, per_page=per_page, error_out=False)
            result = {
                "data": [n.to_dict() for n in pagination.items],
                "total": pagination.total,
                "page": page,
                "pages": pagination.pages,
            }

            if redis_client:
                redis_client.setex(cache_key, 30, json.dumps(result, default=str))

            duration = time.time() - start_time
            NGO_REQUEST_DURATION.labels(
                method="GET", endpoint="/api/v1/ngos", status="200"
            ).observe(duration)
            return jsonify(result)

    @app.route("/api/v1/ngos/<int:ngo_id>", methods=["GET"])
    def get_ngo(ngo_id):
        with tracer.start_as_current_span("get_ngo", attributes={"ngo.id": ngo_id}):
            cache_key = f"ngos:{ngo_id}"

            if redis_client:
                cached = redis_client.get(cache_key)
                if cached:
                    return jsonify(json.loads(cached))

            ngo = db.session.get(NGO, ngo_id)
            if not ngo:
                return jsonify({"error": "NGO not found"}), 404

            result = ngo.to_dict()
            if redis_client:
                redis_client.setex(cache_key, 60, json.dumps(result, default=str))

            return jsonify(result)

    @app.route("/api/v1/ngos", methods=["POST"])
    def create_ngo():
        start_time = time.time()
        with tracer.start_as_current_span("create_ngo"):
            data = request.get_json()
            if not data or not data.get("name") or not data.get("cnpj") or not data.get("contact_email"):
                NGO_ERRORS.labels(error_type="validation").inc()
                duration = time.time() - start_time
                NGO_REQUEST_DURATION.labels(
                    method="POST", endpoint="/api/v1/ngos", status="400"
                ).observe(duration)
                return jsonify({"error": "name, cnpj, and contact_email are required"}), 400
            ngo = NGO(
                name=data["name"],
                cnpj=data["cnpj"],
                description=data.get("description"),
                category=data.get("category"),
                contact_email=data["contact_email"],
                phone=data.get("phone"),
                address=data.get("address"),
                city=data.get("city"),
                state=data.get("state"),
            )
            db.session.add(ngo)
            db.session.commit()
            _invalidate_cache()
            NGO_OPERATIONS.labels(operation="create").inc()
            duration = time.time() - start_time
            NGO_REQUEST_DURATION.labels(
                method="POST", endpoint="/api/v1/ngos", status="201"
            ).observe(duration)
            logger.info("NGO created: id=%d name=%s", ngo.id, ngo.name)
            return jsonify(ngo.to_dict()), 201

    @app.route("/api/v1/ngos/<int:ngo_id>", methods=["PUT"])
    def update_ngo(ngo_id):
        with tracer.start_as_current_span("update_ngo", attributes={"ngo.id": ngo_id}):
            ngo = db.session.get(NGO, ngo_id)
            if not ngo:
                return jsonify({"error": "NGO not found"}), 404
            data = request.get_json()
            allowed_fields = [
                "name", "cnpj", "description", "category",
                "contact_email", "phone", "address", "city", "state",
            ]
            for field in allowed_fields:
                if field in data:
                    setattr(ngo, field, data[field])
            if "active" in data:
                ngo.active = bool(data["active"])
            db.session.commit()
            _invalidate_cache()
            NGO_OPERATIONS.labels(operation="update").inc()
            logger.info("NGO updated: id=%d", ngo.id)
            return jsonify(ngo.to_dict())

    @app.route("/api/v1/ngos/<int:ngo_id>", methods=["DELETE"])
    def delete_ngo(ngo_id):
        with tracer.start_as_current_span("delete_ngo", attributes={"ngo.id": ngo_id}):
            ngo = db.session.get(NGO, ngo_id)
            if not ngo:
                return jsonify({"error": "NGO not found"}), 404
            ngo.active = False
            db.session.commit()
            _invalidate_cache()
            NGO_OPERATIONS.labels(operation="delete").inc()
            logger.info("NGO soft-deleted: id=%d", ngo.id)
            return jsonify({"message": "NGO deactivated"}), 200

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
