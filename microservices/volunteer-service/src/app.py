import logging
import math
import os
import time

from flask import Flask, jsonify, request
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_client import Counter, Histogram, make_wsgi_app
from werkzeug.middleware.dispatcher import DispatcherMiddleware

from models import Campaign, Match, Volunteer, db

SERVICE_NAME = os.getenv("SERVICE_NAME", "volunteer-service")

VOLUNTEER_REQUEST_DURATION = Histogram(
    "volunteer_request_duration_seconds",
    "Time spent processing volunteer requests",
    ["method", "endpoint", "status"],
    buckets=[0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0],
)
VOLUNTEER_ERRORS = Counter(
    "volunteer_errors_total",
    "Total volunteer processing errors",
    ["error_type"],
)
VOLUNTEER_OPERATIONS = Counter(
    "volunteer_operations_total",
    "Total volunteer operations by type",
    ["operation"],
)

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

    # --- Volunteers ---

    @app.route("/api/v1/volunteers", methods=["GET"])
    def list_volunteers():
        with tracer.start_as_current_span("list_volunteers"):
            page = request.args.get("page", 1, type=int)
            per_page = request.args.get("per_page", 20, type=int)
            per_page = min(per_page, 100)

            query = Volunteer.query.order_by(Volunteer.id)
            total = query.count()
            volunteers = query.offset((page - 1) * per_page).limit(per_page).all()

            return jsonify({
                "data": [v.to_dict() for v in volunteers],
                "total": total,
                "page": page,
                "pages": math.ceil(total / per_page) if per_page > 0 else 0,
            })

    @app.route("/api/v1/volunteers/<int:volunteer_id>", methods=["GET"])
    def get_volunteer(volunteer_id):
        with tracer.start_as_current_span("get_volunteer", attributes={"volunteer.id": volunteer_id}):
            vol = db.session.get(Volunteer, volunteer_id)
            if not vol:
                return jsonify({"error": "Volunteer not found"}), 404
            return jsonify(vol.to_dict())

    @app.route("/api/v1/volunteers", methods=["POST"])
    def create_volunteer():
        start_time = time.time()
        with tracer.start_as_current_span("create_volunteer"):
            data = request.get_json()
            if not data or not data.get("name") or not data.get("email"):
                VOLUNTEER_ERRORS.labels(error_type="validation").inc()
                VOLUNTEER_REQUEST_DURATION.labels(
                    method="POST", endpoint="/api/v1/volunteers", status="400"
                ).observe(time.time() - start_time)
                return jsonify({"error": "name and email are required"}), 400

            skills = ",".join(data.get("skills", []))
            vol = Volunteer(
                name=data["name"],
                email=data["email"],
                phone=data.get("phone", ""),
                skills=skills,
                city=data.get("city", ""),
                state=data.get("state", ""),
                available=True,
            )
            db.session.add(vol)
            db.session.commit()
            VOLUNTEER_OPERATIONS.labels(operation="create_volunteer").inc()
            VOLUNTEER_REQUEST_DURATION.labels(
                method="POST", endpoint="/api/v1/volunteers", status="201"
            ).observe(time.time() - start_time)
            logger.info("Volunteer created: id=%d name=%s", vol.id, vol.name)
            return jsonify(vol.to_dict()), 201

    @app.route("/api/v1/volunteers/<int:volunteer_id>", methods=["PUT"])
    def update_volunteer(volunteer_id):
        with tracer.start_as_current_span("update_volunteer", attributes={"volunteer.id": volunteer_id}):
            vol = db.session.get(Volunteer, volunteer_id)
            if not vol:
                return jsonify({"error": "Volunteer not found"}), 404

            data = request.get_json()
            for field in ["name", "email", "phone", "city", "state"]:
                if field in data:
                    setattr(vol, field, data[field])
            if "available" in data:
                vol.available = bool(data["available"])
            if "skills" in data:
                vol.skills = ",".join(data["skills"])

            db.session.commit()
            return jsonify(vol.to_dict())

    @app.route("/api/v1/volunteers/<int:volunteer_id>", methods=["DELETE"])
    def delete_volunteer(volunteer_id):
        with tracer.start_as_current_span("delete_volunteer", attributes={"volunteer.id": volunteer_id}):
            vol = db.session.get(Volunteer, volunteer_id)
            if not vol:
                return jsonify({"error": "Volunteer not found"}), 404
            vol.available = False
            db.session.commit()
            return jsonify({"message": "Volunteer deactivated"})

    # --- Campaigns ---

    @app.route("/api/v1/campaigns", methods=["GET"])
    def list_campaigns():
        with tracer.start_as_current_span("list_campaigns"):
            page = request.args.get("page", 1, type=int)
            per_page = request.args.get("per_page", 20, type=int)
            per_page = min(per_page, 100)

            query = Campaign.query.filter_by(active=True).order_by(Campaign.id)
            total = query.count()
            campaigns = query.offset((page - 1) * per_page).limit(per_page).all()

            return jsonify({
                "data": [c.to_dict() for c in campaigns],
                "total": total,
                "page": page,
                "pages": math.ceil(total / per_page) if per_page > 0 else 0,
            })

    @app.route("/api/v1/campaigns/<int:campaign_id>", methods=["GET"])
    def get_campaign(campaign_id):
        with tracer.start_as_current_span("get_campaign", attributes={"campaign.id": campaign_id}):
            camp = db.session.get(Campaign, campaign_id)
            if not camp:
                return jsonify({"error": "Campaign not found"}), 404
            return jsonify(camp.to_dict())

    @app.route("/api/v1/campaigns", methods=["POST"])
    def create_campaign():
        start_time = time.time()
        with tracer.start_as_current_span("create_campaign"):
            data = request.get_json()
            if not data or not data.get("title") or not data.get("ngo_id"):
                VOLUNTEER_ERRORS.labels(error_type="validation").inc()
                VOLUNTEER_REQUEST_DURATION.labels(
                    method="POST", endpoint="/api/v1/campaigns", status="400"
                ).observe(time.time() - start_time)
                return jsonify({"error": "title and ngo_id are required"}), 400

            skills = ",".join(data.get("required_skills", []))
            camp = Campaign(
                ngo_id=data["ngo_id"],
                title=data["title"],
                description=data.get("description", ""),
                required_skills=skills,
                city=data.get("city", ""),
                state=data.get("state", ""),
                start_date=data.get("start_date"),
                end_date=data.get("end_date"),
                max_volunteers=data.get("max_volunteers", 10),
                active=True,
            )
            db.session.add(camp)
            db.session.commit()
            VOLUNTEER_OPERATIONS.labels(operation="create_campaign").inc()
            VOLUNTEER_REQUEST_DURATION.labels(
                method="POST", endpoint="/api/v1/campaigns", status="201"
            ).observe(time.time() - start_time)
            logger.info("Campaign created: id=%d title=%s", camp.id, camp.title)
            return jsonify(camp.to_dict()), 201

    # --- Matching ---

    @app.route("/api/v1/match", methods=["POST"])
    def create_match():
        start_time = time.time()
        with tracer.start_as_current_span("match_volunteer"):
            data = request.get_json()
            if not data or not data.get("volunteer_id") or not data.get("campaign_id"):
                VOLUNTEER_ERRORS.labels(error_type="validation").inc()
                VOLUNTEER_REQUEST_DURATION.labels(
                    method="POST", endpoint="/api/v1/match", status="400"
                ).observe(time.time() - start_time)
                return jsonify({"error": "volunteer_id and campaign_id are required"}), 400

            volunteer_id = data["volunteer_id"]
            campaign_id = data["campaign_id"]

            vol = db.session.get(Volunteer, volunteer_id)
            if not vol:
                return jsonify({"error": "Volunteer not found"}), 404

            camp = db.session.get(Campaign, campaign_id)
            if not camp:
                return jsonify({"error": "Campaign not found"}), 404

            existing = Match.query.filter_by(volunteer_id=volunteer_id, campaign_id=campaign_id).first()
            if existing:
                return jsonify({"error": "Match already exists", "match": existing.to_dict()}), 409

            accepted_count = Match.query.filter_by(campaign_id=campaign_id, status="accepted").count()
            if accepted_count >= camp.max_volunteers:
                return jsonify({"error": "Campaign is full"}), 400

            match = Match(
                volunteer_id=volunteer_id,
                campaign_id=campaign_id,
                status="pending",
            )
            db.session.add(match)
            db.session.commit()
            VOLUNTEER_OPERATIONS.labels(operation="create_match").inc()
            VOLUNTEER_REQUEST_DURATION.labels(
                method="POST", endpoint="/api/v1/match", status="201"
            ).observe(time.time() - start_time)
            logger.info("Match created: volunteer=%d campaign=%d", volunteer_id, campaign_id)
            return jsonify(match.to_dict()), 201

    @app.route("/api/v1/match/<int:match_id>", methods=["PUT"])
    def update_match(match_id):
        with tracer.start_as_current_span("update_match", attributes={"match.id": match_id}):
            data = request.get_json()
            status = data.get("status", "")
            if status not in ("pending", "accepted", "rejected"):
                return jsonify({"error": "status must be pending, accepted, or rejected"}), 400

            match = db.session.get(Match, match_id)
            if not match:
                return jsonify({"error": "Match not found"}), 404

            match.status = status
            db.session.commit()
            return jsonify(match.to_dict())

    return app


app = create_app()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8082)
