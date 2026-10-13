"""Opt-in API token auth (SYNAPS_API_TOKEN / config.API_TOKEN)."""
import os

import pytest

TOKEN = "s3cret-Token_123"
LAN_ORIGIN = "http://192.168.0.105:3000"
PROTECTED = "/api/sync/history"


@pytest.fixture
def token(monkeypatch):
    import config

    monkeypatch.setattr(config, "API_TOKEN", TOKEN)
    return TOKEN


def test_no_token_configured_means_no_auth(client):
    import config

    assert config.API_TOKEN == ""
    assert client.get(PROTECTED).status_code == 200


def test_missing_token_is_401(client, token):
    r = client.get(PROTECTED)
    assert r.status_code == 401
    assert r.json() == {"detail": "unauthorized"}
    assert r.headers.get("www-authenticate") == "Bearer"


@pytest.mark.parametrize("headers", [
    {"Authorization": f"Bearer {TOKEN}"},
    {"Authorization": f"bearer {TOKEN}"},
    {"Cookie": f"synaps_token={TOKEN}"},
    {"Cookie": f"theme=dark; synaps_token={TOKEN}; other=1"},
    {"Cookie": f'synaps_token="{TOKEN}"'},
])
def test_token_via_header_or_cookie(client, token, headers):
    assert client.get(PROTECTED, headers=headers).status_code == 200


def test_token_via_query_param(client, token):
    assert client.get(PROTECTED, params={"token": TOKEN, "per_page": 1}).status_code == 200


@pytest.mark.parametrize("headers,params", [
    ({"Authorization": "Bearer wrong"}, {}),
    ({"Authorization": f"Token {TOKEN}"}, {}),
    ({"Authorization": TOKEN}, {}),
    ({"Cookie": "synaps_token=wrong"}, {}),
    ({"Cookie": f"not_synaps_token={TOKEN}"}, {}),
    ({}, {"token": "wrong"}),
    ({}, {"token": TOKEN[:-1]}),
    ({}, {"tokenx": TOKEN}),
])
def test_wrong_token_is_401(client, token, headers, params):
    r = client.get(PROTECTED, headers=headers, params=params)
    assert r.status_code == 401
    assert r.json() == {"detail": "unauthorized"}


def test_health_and_non_api_paths_stay_open(client, token):
    assert client.get("/api/health").status_code == 200
    assert client.head("/api/health").status_code == 200
    assert client.get("/health").status_code == 200
    assert client.get("/openapi.json").status_code == 200
    # only GET/HEAD of the health check are exempt
    assert client.post("/api/health").status_code == 401


def test_every_api_router_is_protected(client, token):
    for method, path in [
        ("GET", "/api/media"), ("GET", "/api/finder/browse"), ("GET", "/api/search/?q=x"),
        ("GET", "/api/trash/"), ("GET", "/api/settings/"), ("GET", "/api/import/latest"),
        ("GET", "/api/v2/sources"), ("POST", "/api/v2/ingest/check"), ("POST", "/api/scan"),
        ("GET", "/api/does-not-exist"),
    ]:
        assert client.request(method, path).status_code == 401, path


def test_cors_preflight_is_not_authenticated(client, token):
    r = client.options(PROTECTED, headers={
        "Origin": LAN_ORIGIN,
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization",
    })
    assert r.status_code == 200
    assert r.headers["access-control-allow-origin"] == LAN_ORIGIN


def test_401_carries_cors_headers_for_allowed_origins(client, token):
    r = client.get(PROTECTED, headers={"Origin": LAN_ORIGIN})
    assert r.status_code == 401
    assert r.headers["access-control-allow-origin"] == LAN_ORIGIN
    assert r.headers["access-control-allow-credentials"] == "true"


def test_upload_rejected_before_any_bytes_are_stored(client, clean_db, token, storage_root):
    staging = os.path.join(storage_root, ".synaps_tmp")
    before = set(os.listdir(staging)) if os.path.isdir(staging) else set()
    r = client.put(
        "/api/v2/ingest/stream?source_id=x&original_path=a.jpg&original_filename=a.jpg"
        "&source_location=x&client_sha256=" + "0" * 64,
        content=b"payload",
    )
    assert r.status_code == 401
    after = set(os.listdir(staging)) if os.path.isdir(staging) else set()
    assert after == before


def test_stream_upload_with_query_token(client, clean_db, token):
    from conftest import make_jpeg_bytes, sha256_hex

    data = make_jpeg_bytes() + os.urandom(8)
    r = client.put(
        "/api/v2/ingest/stream",
        params={
            "source_id": "mac_test", "original_path": "/Users/t/auth.jpg", "original_filename": "auth.jpg",
            "source_location": "Pictures", "client_sha256": sha256_hex(data), "token": TOKEN,
        },
        content=data,
    )
    assert r.status_code == 200, r.text


def test_token_change_applies_without_restart(client, monkeypatch):
    import config

    monkeypatch.setattr(config, "API_TOKEN", "first")
    assert client.get(PROTECTED, headers={"Authorization": "Bearer first"}).status_code == 200
    monkeypatch.setattr(config, "API_TOKEN", "second")
    assert client.get(PROTECTED, headers={"Authorization": "Bearer first"}).status_code == 401
    monkeypatch.setattr(config, "API_TOKEN", "")
    assert client.get(PROTECTED).status_code == 200


def test_access_log_redacts_token():
    import logging
    from main import _RedactTokenFilter

    record = logging.LogRecord(
        "uvicorn.access", logging.INFO, __file__, 1, '%s - "%s %s HTTP/%s" %d',
        ("1.2.3.4:5", "GET", f"/api/media/file/1?token={TOKEN}&x=1", "1.1", 200), None,
    )
    assert _RedactTokenFilter().filter(record)
    assert TOKEN not in record.getMessage()
    assert "token=***&x=1" in record.getMessage()
