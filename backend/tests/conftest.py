"""
Shared pytest fixtures for the Synaps backend.

Every test session runs against a throwaway storage root, database, thumbnail
cache and trash directory, so the real synaps.db and media are never touched.
The SYNAPS_* env vars must be set before `config` is first imported, which is
why they are assigned at module import time here.
"""
import hashlib
import io
import os
import shutil
import sys
import tempfile

import pytest

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_SESSION_ROOT = tempfile.mkdtemp(prefix="synaps-tests-")

os.environ["SYNAPS_STORAGE_PATH"] = os.path.join(_SESSION_ROOT, "storage")
os.environ["SYNAPS_DB_URL"] = f"sqlite:///{os.path.join(_SESSION_ROOT, 'synaps-test.db')}"
os.environ["SYNAPS_THUMBNAIL_DIR"] = os.path.join(_SESSION_ROOT, "thumbnails")
os.environ["SYNAPS_TRASH_DIR"] = os.path.join(_SESSION_ROOT, "trash")
# Empty means "auth disabled"; set explicitly so a local .env can't enable it.
os.environ["SYNAPS_API_TOKEN"] = ""
for _sub in ("storage", "thumbnails", "trash"):
    os.makedirs(os.path.join(_SESSION_ROOT, _sub), exist_ok=True)

if BACKEND_DIR not in sys.path:
    sys.path.insert(0, BACKEND_DIR)


def pytest_sessionfinish(session, exitstatus):
    shutil.rmtree(_SESSION_ROOT, ignore_errors=True)


@pytest.fixture(scope="session")
def app():
    import main
    from database import init_db

    init_db()
    return main.app


@pytest.fixture(scope="session")
def client(app):
    from fastapi.testclient import TestClient

    with TestClient(app) as c:
        yield c


@pytest.fixture
def db_session(app):
    from database import SessionLocal

    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


@pytest.fixture
def clean_db(app):
    """Empty every table so a test starts from a known-empty database."""
    from database import Base, engine

    with engine.begin() as conn:
        for table in reversed(Base.metadata.sorted_tables):
            conn.execute(table.delete())
    yield


@pytest.fixture(scope="session")
def storage_root():
    return os.environ["SYNAPS_STORAGE_PATH"]


def make_jpeg_bytes(size=(64, 48), color=(200, 30, 30)) -> bytes:
    """Small valid JPEG for upload/thumbnail tests."""
    from PIL import Image

    buf = io.BytesIO()
    Image.new("RGB", size, color).save(buf, format="JPEG", quality=85)
    return buf.getvalue()


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()
