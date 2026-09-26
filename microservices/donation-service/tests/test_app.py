import json


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "healthy"
    assert data["service"] == "donation-service"


def test_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200


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


def test_create_donation_validation(client):
    response = client.post(
        "/api/v1/donations",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_create_donation_invalid_currency(client):
    payload = {
        "donor_name": "Teste",
        "amount": 50,
        "payment_method": "pix",
        "currency": "XYZ",
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
    assert "golden_metrics" in data
    assert "slo" in data


def test_get_donation_not_found(client):
    response = client.get("/api/v1/donations/99999")
    assert response.status_code == 404
