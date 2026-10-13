"""migrations/backfill_v2_media_files.py: v1 timeline rows for existing v2 objects."""
import importlib.util
import os
import sys
from urllib.parse import urlencode

import pytest

from conftest import BACKEND_DIR, make_jpeg_bytes, sha256_hex


def load_backfill():
    path = os.path.join(BACKEND_DIR, "migrations", "backfill_v2_media_files.py")
    spec = importlib.util.spec_from_file_location("backfill_v2_media_files", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run_backfill(monkeypatch, *args):
    module = load_backfill()
    monkeypatch.setattr(sys, "argv", ["backfill_v2_media_files.py", *args])
    assert module.main() == 0


def upload(client, data, path, source_id="iphone_test"):
    params = urlencode({
        "source_id": source_id, "original_path": path, "original_filename": os.path.basename(path),
        "source_location": "Photos", "client_sha256": sha256_hex(data),
    })
    r = client.put("/api/v2/ingest/stream?" + params, content=data)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture
def legacy_v2_library(client, clean_db, db_session, storage_root):
    """v2 objects as the old ingest left them: no media_files rows, drifted reference counts."""
    from models import MediaFile
    from models_v2 import PhysicalObject

    photo = upload(client, make_jpeg_bytes() + os.urandom(8), "Camera Roll/IMG_1.JPG")
    video = upload(client, b"\x00\x00\x00\x18ftypqt  " + os.urandom(64), "Camera Roll/IMG_2.MOV")
    scanned = upload(client, make_jpeg_bytes() + os.urandom(8), "/Users/x/Pictures/scanned.jpg", source_id="mac_test")
    doc = upload(client, b"%PDF-1.4" + os.urandom(8), "/Users/x/doc.pdf", source_id="mac_test")
    gone = upload(client, make_jpeg_bytes() + os.urandom(8), "Camera Roll/IMG_3.JPG")
    os.remove(os.path.join(storage_root, gone["canonical_path"]))

    canonical = lambda body: os.path.join(storage_root, body["canonical_path"])  # noqa: E731
    db_session.query(MediaFile).filter(MediaFile.path != canonical(scanned)).delete()
    # what a manual /api/scan made of a Vault/YYYY/MM file: month as source, no content hash
    db_session.query(MediaFile).filter(MediaFile.path == canonical(scanned)).update(
        {"source": "10", "content_hash": None})
    db_session.query(PhysicalObject).update({"reference_count": 5})
    db_session.commit()
    return {"photo": canonical(photo), "video": canonical(video), "scanned": canonical(scanned),
            "doc": canonical(doc), "gone": canonical(gone)}


def test_dry_run_changes_nothing(monkeypatch, capsys, legacy_v2_library, db_session):
    from models import MediaFile

    run_backfill(monkeypatch, "--dry-run", "--fix-reference-counts")
    out = capsys.readouterr().out
    assert "Would create media_files rows:      2" in out
    assert "Would fix meaningless source:       1" in out
    db_session.expire_all()
    assert db_session.query(MediaFile).count() == 1


def test_backfill_creates_rows_once(monkeypatch, capsys, legacy_v2_library, db_session):
    from models import MediaFile
    from models_v2 import PhysicalObject

    run_backfill(monkeypatch, "--fix-reference-counts")
    db_session.expire_all()
    rows = {m.path: m for m in db_session.query(MediaFile).all()}
    lib = legacy_v2_library
    assert set(rows) == {lib["photo"], lib["video"], lib["scanned"]}  # not the PDF, not the missing file
    assert rows[lib["photo"]].source == "iphone" and rows[lib["photo"]].filename == "IMG_1.JPG"
    assert rows[lib["video"]].media_type == "video"
    assert rows[lib["scanned"]].source == "mac" and rows[lib["scanned"]].content_hash
    assert all("Mirrors" not in m.path for m in rows.values())
    assert {p.reference_count for p in db_session.query(PhysicalObject).all()} == {1}

    capsys.readouterr()
    run_backfill(monkeypatch)
    out = capsys.readouterr().out
    assert "Did create media_files rows:      0" in out
    db_session.expire_all()
    assert db_session.query(MediaFile).count() == 3
