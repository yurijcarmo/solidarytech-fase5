import json
from types import SimpleNamespace
from unittest.mock import MagicMock

from app import write_audit_log


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "healthy"
    assert data["service"] == "donation-service"


def test_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "ready"
    assert data["checks"]["database"] == "ok"


def test_list_donations(client):
    response = client.get("/api/v1/donations")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "data" in data
    assert "total" in data


def test_list_currencies(client):
    response = client.get("/api/v1/donations/currencies")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "supported_currencies" in data
    assert "BRL" in data["supported_currencies"]


def test_create_donation(client):
    payload = {
        "donor_name": "Joao Teste",
        "amount": 100.00,
        "payment_method": "pix",
        "currency": "BRL",
        "ngo_id": 1,
    }
    response = client.post(
        "/api/v1/donations",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 201
    data = json.loads(response.data)
    assert data["donor_name"] == "Joao Teste"
    assert data["amount"] == 100.0


def test_create_donation_uses_decimal_conversion(client):
    payload = {
        "donor_name": "Teste Decimal",
        "amount": "0.10",
        "payment_method": "pix",
        "currency": "USD",
        "ngo_id": 1,
    }
    response = client.post(
        "/api/v1/donations",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 201
    assert json.loads(response.data)["amount"] == 0.55


def test_create_donation_validation(client):
    response = client.post(
        "/api/v1/donations",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_create_donation_requires_ngo_id(client):
    payload = {
        "donor_name": "Teste",
        "amount": 50,
        "payment_method": "pix",
        "currency": "BRL",
    }
    response = client.post(
        "/api/v1/donations",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_create_donation_rejects_non_finite_amount(client):
    payload = {
        "donor_name": "Teste",
        "amount": "NaN",
        "payment_method": "pix",
        "currency": "BRL",
        "ngo_id": 1,
    }
    response = client.post(
        "/api/v1/donations",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_create_donation_invalid_currency(client):
    payload = {
        "donor_name": "Teste",
        "amount": 50,
        "payment_method": "pix",
        "currency": "XYZ",
        "ngo_id": 1,
    }
    response = client.post(
        "/api/v1/donations",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_donation_stats(client):
    response = client.get("/api/v1/donations/stats")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "total_donations" in data


def test_golden_metrics(client):
    response = client.get("/api/v1/donations/metrics/golden")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["golden_metrics"]["traffic"] == "http_requests_total"
    assert data["golden_metrics"]["latency"] == "http_request_duration_seconds"
    assert "slo" in data


def test_prometheus_http_metrics(client):
    client.get("/health")
    response = client.get("/metrics")
    assert response.status_code == 200
    assert b"http_requests_total" in response.data
    assert b"http_request_duration_seconds" in response.data


def test_audit_log_does_not_store_donor_pii():
    table = MagicMock()
    donation = SimpleNamespace(
        id=10,
        donor_name="Pessoa Teste",
        donor_email="pessoa@example.com",
        ngo_id=7,
        payment_method="pix",
        status="pending",
    )

    created_at = write_audit_log(table, donation, "tx-123", "BRL", "100.00", "100.00")

    assert created_at is not None
    item = table.put_item.call_args.kwargs["Item"]
    assert "donor_name" not in item
    assert "donor_email" not in item
    assert item["donation_id"] == 10
    assert item["transaction_id"] == "tx-123"


def test_get_donation_not_found(client):
    response = client.get("/api/v1/donations/99999")
    assert response.status_code == 404
