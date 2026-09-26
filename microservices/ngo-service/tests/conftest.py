import os
import sys
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))
os.environ.setdefault("DATABASE_URL", "sqlite:///:memory:")


@pytest.fixture
def app():
    from app import create_app
    application = create_app()
    application.config["TESTING"] = True
    yield application


@pytest.fixture
def client(app):
    return app.test_client()
