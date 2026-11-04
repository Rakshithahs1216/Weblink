import time

import jwt
import pytest
from conftest import TEST_SECRET

from app.auth import JWT_ISSUER, TokenService


def login(client, username="demo", password="demo1234"):
    return client.post("/api/auth/login", json={"username": username, "password": password})


def test_health(client):
    r = client.get("/api/health")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


@pytest.mark.parametrize("identifier", ["demo", "demo@weblink.local", "DEMO@weblink.local"])
def test_login_by_username_or_email(client, identifier):
    r = login(client, identifier)
    assert r.status_code == 200
    body = r.json()
    assert body["token_type"] == "bearer"
    assert body["expires_in"] == 3600
    assert body["user"] == {"username": "demo", "display_name": "Demo Operator"}

    claims = jwt.decode(body["access_token"], TEST_SECRET, algorithms=["HS256"], issuer=JWT_ISSUER)
    assert claims["sub"] == "demo"
    assert claims["exp"] - claims["iat"] == 3600


@pytest.mark.parametrize(
    "username,password", [("demo", "wrong"), ("nobody", "demo1234"), ("demo", "")]
)
def test_login_bad_credentials(client, username, password):
    r = login(client, username, password)
    assert r.status_code == 401
    assert r.json() == {"detail": "Invalid username or password"}


def test_login_missing_fields_is_rejected(client):
    assert client.post("/api/auth/login", json={"username": "demo"}).status_code == 422


def test_me_with_token(client):
    token = login(client).json()["access_token"]
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json() == {"username": "demo", "display_name": "Demo Operator"}


@pytest.mark.parametrize(
    "headers",
    [{}, {"Authorization": "Bearer not-a-jwt"}, {"Authorization": "Basic ZGVtbzpkZW1vMTIzNA=="}],
)
def test_me_without_valid_token(client, headers):
    r = client.get("/api/auth/me", headers=headers)
    assert r.status_code == 401
    assert "detail" in r.json()


def test_me_with_expired_token(client):
    token = TokenService(TEST_SECRET, 60).create("demo", now=time.time() - 7200)
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401
    assert r.json() == {"detail": "Token has expired"}


def test_me_with_token_signed_by_other_secret(client):
    token = TokenService("some-other-secret-that-is-long-enough!!", 60).create("demo")
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401


def test_me_with_wrong_issuer(client):
    now = int(time.time())
    token = jwt.encode(
        {"sub": "demo", "iat": now, "exp": now + 60, "iss": "evil"}, TEST_SECRET, algorithm="HS256"
    )
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401


def test_me_with_unknown_user(client):
    token = TokenService(TEST_SECRET, 60).create("ghost")
    r = client.get("/api/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 401
