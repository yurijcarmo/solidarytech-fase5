import json


def test_health(client):
    response = client.get("/health")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert data["status"] == "healthy"
    assert data["service"] == "volunteer-service"


def test_ready(client):
    response = client.get("/ready")
    assert response.status_code == 200


def test_list_volunteers(client):
    response = client.get("/api/v1/volunteers")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "data" in data
    assert "total" in data


def test_create_volunteer(client):
    payload = {
        "name": "Maria Teste",
        "email": "maria@teste.com",
        "skills": ["python", "docker"],
        "city": "Sao Paulo",
        "state": "SP",
    }
    response = client.post(
        "/api/v1/volunteers",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 201
    data = json.loads(response.data)
    assert data["name"] == "Maria Teste"


def test_create_volunteer_validation(client):
    response = client.post(
        "/api/v1/volunteers",
        data=json.dumps({}),
        content_type="application/json",
    )
    assert response.status_code == 400


def test_get_volunteer_not_found(client):
    response = client.get("/api/v1/volunteers/99999")
    assert response.status_code == 404


def test_list_campaigns(client):
    response = client.get("/api/v1/campaigns")
    assert response.status_code == 200
    data = json.loads(response.data)
    assert "data" in data


def test_create_campaign(client):
    payload = {
        "title": "Campanha Teste",
        "ngo_id": 1,
        "description": "Descricao da campanha",
        "required_skills": ["python"],
    }
    response = client.post(
        "/api/v1/campaigns",
        data=json.dumps(payload),
        content_type="application/json",
    )
    assert response.status_code == 201
    data = json.loads(response.data)
    assert data["title"] == "Campanha Teste"


def test_create_match(client):
    vol_resp = client.post(
        "/api/v1/volunteers",
        data=json.dumps({"name": "Vol", "email": "vol@t.com"}),
        content_type="application/json",
    )
    camp_resp = client.post(
        "/api/v1/campaigns",
        data=json.dumps({"title": "Camp", "ngo_id": 1}),
        content_type="application/json",
    )
    vol_id = json.loads(vol_resp.data)["id"]
    camp_id = json.loads(camp_resp.data)["id"]

    response = client.post(
        "/api/v1/match",
        data=json.dumps({
            "volunteer_id": vol_id,
            "campaign_id": camp_id,
        }),
        content_type="application/json",
    )
    assert response.status_code == 201
