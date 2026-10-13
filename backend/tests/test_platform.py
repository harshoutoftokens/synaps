"""Platform: SQLite tuning, CORS, optional static frontend, housekeeping, config."""
import os
import re
import threading
import time

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient


def test_sqlite_runs_in_wal_mode_with_busy_timeout(app):
    from sqlalchemy import text
    from database import engine

    with engine.connect() as conn:
        assert conn.execute(text("PRAGMA journal_mode")).scalar().lower() == "wal"
        assert conn.execute(text("PRAGMA busy_timeout")).scalar() == 30000
        assert conn.execute(text("PRAGMA synchronous")).scalar() == 1  # NORMAL
        assert conn.execute(text("PRAGMA foreign_keys")).scalar() == 0  # deliberately off


def test_init_db_creates_v1_and_v2_tables(app):
    from sqlalchemy import inspect
    from database import engine, init_db

    init_db()  # idempotent
    tables = set(inspect(engine).get_table_names())
    assert {"media_files", "trash_items", "sync_records", "settings", "sources", "physical_objects",
            "filesystem_nodes", "logical_items", "albums", "album_items", "media_metadata"} <= tables


def test_extra_indexes_created_idempotently(app):
    from sqlalchemy import inspect
    from database import engine, init_db

    init_db()
    init_db()  # second run is a no-op
    inspector = inspect(engine)
    media = {ix["name"]: ix["column_names"] for ix in inspector.get_indexes("media_files")}
    logical = {ix["name"]: ix["column_names"] for ix in inspector.get_indexes("logical_items")}
    assert media["ix_media_files_file_size"] == ["file_size"]
    assert media["ix_media_files_date_taken_id"] == ["date_taken", "id"]
    assert logical["ix_logical_items_original_filename"] == ["original_filename"]


def test_readers_are_not_blocked_by_a_writer(app):
    """WAL: an open write transaction (e.g. a long ingest) doesn't block timeline reads."""
    from sqlalchemy import text
    from database import engine

    with engine.connect() as writer:
        writer.execute(text("BEGIN IMMEDIATE"))
        writer.execute(text("INSERT INTO settings (key, value) VALUES ('wal_probe', 'x')"))
        t0 = time.monotonic()
        with engine.connect() as reader:
            reader.execute(text("SELECT COUNT(*) FROM media_files")).scalar()
        assert time.monotonic() - t0 < 1.0
        writer.execute(text("ROLLBACK"))


def test_config_defaults_keep_existing_layout():
    import config

    storage = config.STORAGE_PATH
    assert config.OWNER_NAME == "Harsh" and config.MIRROR_OWNER == "Harsh"
    assert config.SYNC_TARGET_DIR == os.path.join(storage, "Vault", "Harsh", "Iphone")
    assert config.IMPORT_SOURCE_DIR == os.path.join(storage, "Imports", "harsh", "Iphone")
    assert config.IMPORT_DEST_BASE == os.path.join(storage, "Vault", "Harsh", "Iphone")
    assert {"Vault/Windows_laptop-HP", "Vault/Harsh/Mac/Private", "Mirrors", ".synaps_tmp"} <= set(config.EXCLUDED_PATHS)


def test_mirror_base_uses_configured_owner(monkeypatch):
    import storage_engine

    assert storage_engine.get_mirror_base_for_source("Harsh's Mac", "macOS") == os.path.join("Harsh", "Mac")
    assert storage_engine.get_mirror_base_for_source("iphone_harsh", "iOS") == os.path.join("Harsh", "Iphone")
    monkeypatch.setattr(storage_engine, "MIRROR_OWNER", "Asha")
    assert storage_engine.get_mirror_base_for_source("iphone_x", "iOS") == os.path.join("Asha", "Iphone")
    assert storage_engine.get_mirror_base_for_source("win_laptop_hp", "Windows") == "Windows_laptop-HP"


def test_excluded_paths_match_scanner_logic(storage_root):
    """The scanner compares EXCLUDED_PATHS against paths relative to STORAGE_PATH."""
    import config

    normalized = [os.path.normpath(p) for p in config.EXCLUDED_PATHS]

    def excluded(rel):
        return any(rel == ep or rel.startswith(ep + os.sep) for ep in normalized)

    assert excluded("Mirrors")
    assert excluded(os.path.join("Mirrors", "Harsh", "Mac", "Downloads"))
    assert excluded(".synaps_tmp")
    assert not excluded(os.path.join("Vault", "2024", "05"))
    assert not excluded("MirrorsX")


# ── CORS ──────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("origin,allowed", [
    ("http://192.168.0.105:3000", True),
    ("http://10.0.0.5:3000", True),
    ("http://172.20.1.1:3000", True),
    ("http://localhost:3000", True),
    ("http://127.0.0.1:3000", True),
    ("http://homecloud1.local:3000", True),
    ("http://100.101.102.103:3000", True),  # Tailscale
    ("http://192.168.0.105:8000", False),  # only the dashboard port
    ("http://192.168.0.105", False),
    ("https://evil.example", False),
    ("http://evil.example:3000", False),
    ("http://192.168.0.105.evil.example:3000", False),
    ("http://evil.ts.net:3000", False),
    ("http://172.32.0.1:3000", False),
    ("http://100.128.0.1:3000", False),
    ("null", False),
])
def test_default_cors_origin_regex(origin, allowed):
    import config

    assert bool(re.fullmatch(config.DEFAULT_CORS_ORIGIN_REGEX, origin)) is allowed


def test_cors_origin_env_overrides_default(monkeypatch):
    import importlib
    import config

    try:
        monkeypatch.setenv("SYNAPS_CORS_ORIGINS", "https://photos.example.com, http://nas.lan:3000")
        importlib.reload(config)
        assert config.CORS_ORIGINS == ["https://photos.example.com", "http://nas.lan:3000"]
        assert config.CORS_ORIGIN_REGEX == ""  # explicit list replaces the LAN default
        monkeypatch.setenv("SYNAPS_CORS_ORIGIN_REGEX", r"https://.*\.example\.com")
        importlib.reload(config)
        assert config.CORS_ORIGIN_REGEX == r"https://.*\.example\.com"
        monkeypatch.delenv("SYNAPS_CORS_ORIGINS")
        monkeypatch.delenv("SYNAPS_CORS_ORIGIN_REGEX")
        importlib.reload(config)
        assert config.CORS_ORIGINS == [] and config.CORS_ORIGIN_REGEX == config.DEFAULT_CORS_ORIGIN_REGEX
    finally:
        monkeypatch.undo()
        importlib.reload(config)


def test_cors_allows_lan_origin_with_credentials(client):
    origin = "http://192.168.0.105:3000"
    r = client.get("/api/health", headers={"Origin": origin})
    assert r.headers["access-control-allow-origin"] == origin
    assert r.headers["access-control-allow-credentials"] == "true"
    pre = client.options("/api/sync/upload", headers={"Origin": origin, "Access-Control-Request-Method": "POST"})
    assert pre.status_code == 200 and pre.headers["access-control-allow-origin"] == origin


def test_cors_does_not_trust_other_sites(client):
    r = client.get("/api/health", headers={"Origin": "https://evil.example"})
    assert "access-control-allow-origin" not in r.headers
    pre = client.options("/api/media", headers={"Origin": "https://evil.example", "Access-Control-Request-Method": "GET"})
    assert pre.headers.get("access-control-allow-origin") != "https://evil.example"


# ── Optional static frontend ──────────────────────────────────────────────

def test_static_frontend_is_served_after_api_routes(tmp_path):
    from main import mount_frontend

    dist = tmp_path / "out"
    (dist / "_next" / "static").mkdir(parents=True)
    (dist / "index.html").write_text("<html>home</html>")
    (dist / "timeline.html").write_text("<html>timeline</html>")
    (dist / "_next" / "static" / "app.js").write_text("console.log(1)")

    web = FastAPI()

    @web.get("/api/ping")
    def ping():
        return {"pong": True}

    @web.put("/api/upload-only")
    def upload_only():
        return {"ok": True}

    assert mount_frontend(web, str(dist)) is True
    c = TestClient(web)
    assert c.get("/").text == "<html>home</html>"
    assert c.get("/timeline").text == "<html>timeline</html>"
    assert c.get("/_next/static/app.js").text == "console.log(1)"
    assert c.get("/api/ping").json() == {"pong": True}
    missing_api = c.get("/api/nope")
    assert missing_api.status_code == 404 and missing_api.json() == {"detail": "Not Found"}
    # wrong method on an API route is still 405 (clients probe PUT-only routes with GET)
    assert c.get("/api/upload-only").status_code == 405
    assert c.get("/no-such-page").status_code == 404


def test_stream_route_probe_answers_405(client):
    """The Mac app detects PUT /api/v2/ingest/stream support with a GET: 405 = supported."""
    assert client.get("/api/v2/ingest/stream").status_code == 405


def test_static_frontend_disabled_when_unset_or_missing(tmp_path):
    from main import mount_frontend

    assert mount_frontend(FastAPI(), "") is False
    assert mount_frontend(FastAPI(), str(tmp_path / "missing")) is False


def test_backend_app_has_no_frontend_mount_by_default(app):
    assert not [r for r in app.routes if getattr(r, "name", "") == "frontend"]


# ── Housekeeping ──────────────────────────────────────────────────────────

def test_staging_sweep_removes_only_stale_partial_uploads(storage_root):
    from storage_engine import sweep_stale_staging

    staging = os.path.join(storage_root, ".synaps_tmp")
    trash = os.path.join(storage_root, ".synaps_trash")
    os.makedirs(staging, exist_ok=True)
    os.makedirs(trash, exist_ok=True)
    stale_new = os.path.join(staging, "0123456789abcdef0123456789abcdef.upload.jpg")
    stale_old = os.path.join(staging, "6f1c0d8e-1111-2222-3333-444455556666.upload")
    fresh = os.path.join(staging, "fedcba9876543210fedcba9876543210.upload.heic")
    not_upload = os.path.join(staging, "notes.txt")
    trashed = os.path.join(trash, "IMG_1.upload")
    old = time.time() - 7 * 3600
    for p in (stale_new, stale_old, fresh, not_upload, trashed):
        with open(p, "wb") as f:
            f.write(b"partial")
        if p != fresh:
            os.utime(p, (old, old))

    assert sweep_stale_staging(6 * 3600) == 2
    assert not os.path.exists(stale_new) and not os.path.exists(stale_old)
    assert os.path.exists(fresh) and os.path.exists(not_upload) and os.path.exists(trashed)
    for p in (fresh, not_upload, trashed):
        os.remove(p)


def test_trash_purge_uses_trash_router_cleanup(app, monkeypatch, caplog):
    import logging
    import main
    import routers.trash as trash

    calls = []

    def fake_cleanup(db):
        calls.append(db)
        return {"status": "success", "deleted": 3, "errors": 1}

    monkeypatch.setattr(trash, "cleanup_expired", fake_cleanup)
    with caplog.at_level(logging.INFO, logger="synaps"):
        main.purge_expired_trash()
    assert len(calls) == 1
    assert "'deleted': 3" in caplog.text and "'errors': 1" in caplog.text

    def broken(db):
        raise RuntimeError("disk on fire")

    monkeypatch.setattr(trash, "cleanup_expired", broken)
    main.purge_expired_trash()  # logged, not raised


def test_trash_purge_wiring_with_real_cleanup(app, clean_db, caplog):
    """The real routers.trash.cleanup_expired(db) runs from the housekeeping job without errors."""
    import logging
    import main

    with caplog.at_level(logging.WARNING, logger="synaps"):
        main.purge_expired_trash()
    assert not [r for r in caplog.records if "Trash purge" in r.getMessage()]


def test_housekeeping_thread_started(client):
    assert any(t.name == "synaps-housekeeping" and t.daemon for t in threading.enumerate())


def test_only_one_scan_runs_at_a_time(client, monkeypatch):
    import main

    release = threading.Event()
    started = threading.Event()

    def fake_scan():
        started.set()
        release.wait(10)

    monkeypatch.setattr(main, "run_initial_scan", fake_scan)
    assert client.post("/api/scan").json() == {"status": "scan_started"}
    assert started.wait(5)
    assert client.post("/api/scan").json() == {"status": "scan_already_running"}
    release.set()
    for _ in range(50):
        if not main._scan_lock.locked():
            break
        time.sleep(0.05)
    started.clear()
    release.clear()
    assert client.post("/api/scan").json() == {"status": "scan_started"}
    release.set()
