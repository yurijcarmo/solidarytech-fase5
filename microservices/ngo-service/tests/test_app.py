import json


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "healthy"
    assert data["service"] == "ngo-service"


def test_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200


def test_list_ngos(client):
    response = client.get("/api/v1/ngos")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "data" in data
    assert "total" in data


def test_create_ngo(client):
    payload = {
        "name": "ONG Teste",
        "cnpj": "12.345.678/0001-00",
        "contact_email": "teste@ong.org",
    }
    response = client.post(
        "/api/v1/ngos",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 201
    data = json.loads(response.data)
    assert data["name"] == "ONG Teste"


def test_create_ngo_validation(client):
    response = client.post(
        "/api/v1/ngos",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_get_ngo_not_found(client):
    response = client.get("/api/v1/ngos/99999")
    assert response.status_code == 404
