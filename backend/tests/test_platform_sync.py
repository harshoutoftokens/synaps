"""Legacy v1 uploads (/api/sync, the web app) and the Import Manager."""
import io
import os
import re
from datetime import datetime

import pytest

from conftest import make_jpeg_bytes, sha256_hex


def jpeg(tag: str = "") -> bytes:
    return make_jpeg_bytes(color=(30, 160, 90)) + os.urandom(16) + tag.encode()


def web_upload(client, data: bytes, filename: str, device="iPhone"):
    return client.post(
        "/api/sync/upload",
        data={"device": device},
        files={"file": (filename, data, "image/jpeg")},
    )


def month_dir():
    import config

    now = datetime.now()
    return os.path.join(config.SYNC_TARGET_DIR, str(now.year), f"{now.month:02d}")


def test_web_upload_stores_records_and_indexes(client, clean_db, db_session, storage_root):
    from models import MediaFile, SyncRecord

    data = jpeg()
    name = f"IMG_{os.urandom(4).hex()}.jpg"
    r = web_upload(client, data, name)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "success" and body["filename"] == name and body["size"] == len(data)
    assert body["path"] == os.path.join(month_dir(), name)
    with open(body["path"], "rb") as f:
        assert f.read() == data
    # no partial upload left behind (other tests may park unrelated fixtures in the folder)
    assert not [n for n in os.listdir(os.path.join(storage_root, ".synaps_tmp")) if re.match(r"^[0-9a-f]{32}\.upload", n)]

    record = db_session.query(SyncRecord).one()
    assert record.content_hash == sha256_hex(data) and record.file_size == len(data)
    # The timeline sees it immediately (no rescan needed)
    media = db_session.query(MediaFile).filter(MediaFile.path == body["path"]).one()
    assert media.id == body["media_id"]
    assert media.source == "iphone" and media.content_hash == sha256_hex(data)


def test_web_upload_dedup(client, clean_db):
    data = jpeg()
    assert web_upload(client, data, "first.jpg").json()["status"] == "success"
    again = web_upload(client, data, "renamed.jpg").json()
    assert again["status"] == "duplicate" and again["filename"] == "first.jpg"


def test_web_upload_dedups_against_v2_vault(client, clean_db):
    from urllib.parse import urlencode

    data = jpeg()
    params = urlencode({
        "source_id": "iphone_test", "original_path": "Camera Roll/IMG_9.jpg", "original_filename": "IMG_9.jpg",
        "source_location": "Photos", "client_sha256": sha256_hex(data),
    })
    assert client.put("/api/v2/ingest/stream?" + params, content=data).status_code == 200
    r = web_upload(client, data, "IMG_9_copy.jpg").json()
    assert r["status"] == "duplicate"


def test_web_upload_dedups_against_scanned_file_by_content(client, clean_db, db_session, storage_root):
    """media_files.file_hash only covers the first 64 KB: confirm with the full SHA-256."""
    from models import MediaFile
    from scanner import compute_file_hash

    big = jpeg() + os.urandom(100_000)
    lookalike = big[:-1] + bytes([big[-1] ^ 0xFF])  # same size, same first 64 KB, different file
    folder = os.path.join(storage_root, "Vault", "Harsh", "Mac", "scanned")
    os.makedirs(folder, exist_ok=True)
    path = os.path.join(folder, "scanned.jpg")
    with open(path, "wb") as f:
        f.write(big)
    db_session.add(MediaFile(
        filename="scanned.jpg", path=path, relative_path=os.path.relpath(path, storage_root),
        directory="Vault/Harsh/Mac/scanned", extension=".jpg", media_type="image",
        file_size=len(big), file_hash=compute_file_hash(path),
    ))
    db_session.commit()

    assert web_upload(client, lookalike, "lookalike.jpg").json()["status"] == "success"
    dup = web_upload(client, big, "copy.jpg").json()
    assert dup["status"] == "duplicate" and dup["filename"] == "scanned.jpg"
    db_session.expire_all()
    assert db_session.query(MediaFile).filter(MediaFile.path == path).one().content_hash == sha256_hex(big)


def test_web_upload_cannot_escape_target_folder(client, clean_db, storage_root):
    r = web_upload(client, jpeg(), "../../../../escape.jpg")
    assert r.status_code == 200
    body = r.json()
    assert body["filename"] == "escape.jpg"
    assert os.path.dirname(body["path"]) == month_dir()
    assert not os.path.exists(os.path.join(storage_root, "escape.jpg"))


def test_web_upload_same_name_never_overwrites(client, clean_db):
    name = f"same_{os.urandom(3).hex()}.jpg"
    a, b = jpeg("a"), jpeg("b")
    ra = web_upload(client, a, name).json()
    rb = web_upload(client, b, name).json()
    assert ra["status"] == rb["status"] == "success"
    assert ra["path"] != rb["path"] and rb["filename"] == name.replace(".jpg", "_1.jpg")
    with open(ra["path"], "rb") as f:
        assert f.read() == a


def test_web_upload_rejects_unsupported_and_nameless(client):
    assert web_upload(client, b"text", "notes.txt").status_code == 400


def test_web_batch_upload(client, clean_db):
    data = jpeg()
    r = client.post(
        "/api/sync/upload-batch",
        data={"device": "iPhone"},
        files=[
            ("files", ("b1.jpg", data, "image/jpeg")),
            ("files", ("b2.jpg", data, "image/jpeg")),
            ("files", ("b3.txt", b"x", "text/plain")),
        ],
    )
    assert r.status_code == 200
    body = r.json()
    assert (body["total"], body["success"], body["duplicates"], body["errors"]) == (3, 1, 1, 0)
    assert [x["status"] for x in body["results"]] == ["success", "duplicate", "skipped"]


def test_sync_history_paging_bounds(client):
    assert client.get("/api/sync/history", params={"per_page": 1}).status_code == 200
    assert client.get("/api/sync/history", params={"page": 0}).status_code == 422


# ── Import Manager ────────────────────────────────────────────────────────

@pytest.fixture
def import_dirs(storage_root):
    import config
    import shutil

    for d in (config.IMPORT_SOURCE_DIR, config.IMPORT_DEST_BASE):
        shutil.rmtree(d, ignore_errors=True)
        os.makedirs(d, exist_ok=True)
    return config.IMPORT_SOURCE_DIR, config.IMPORT_DEST_BASE


def _write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)


def test_import_moves_dedups_and_indexes(clean_db, db_session, import_dirs):
    from import_manager import ImportJob, _run_import
    from models import MediaFile

    src, dest = import_dirs
    keep, twin, existing_name_other_content = jpeg("keep"), jpeg("twin"), jpeg("other")
    _write(os.path.join(src, "IMG_20240115_101010.jpg"), keep)
    _write(os.path.join(src, "a", "IMG_20240116_101010.jpg"), twin)
    _write(os.path.join(src, "b", "IMG_20240116_101010_copy.jpg"), twin)  # same content twice in one import
    # A different photo already uses this name at the destination: must not be skipped
    _write(os.path.join(dest, "2024", "01", "IMG_20240117_101010.jpg"), existing_name_other_content)
    _write(os.path.join(src, "IMG_20240117_101010.jpg"), jpeg("new-content-same-name"))

    job = ImportJob(id="test")
    _run_import(src, job)
    assert job.status == "complete", job.error_log
    assert job.imported == 3 and job.duplicates_skipped == 1 and job.errors == 0

    jan = sorted(os.listdir(os.path.join(dest, "2024", "01")))
    assert "IMG_20240115_101010.jpg" in jan
    assert "IMG_20240117_101010_1.jpg" in jan  # imported next to the different file
    with open(os.path.join(dest, "2024", "01", "IMG_20240117_101010.jpg"), "rb") as f:
        assert f.read() == existing_name_other_content

    indexed = {m.filename: m for m in db_session.query(MediaFile).all()}
    assert {"IMG_20240115_101010.jpg", "IMG_20240117_101010_1.jpg"} <= set(indexed)
    assert indexed["IMG_20240115_101010.jpg"].source == "iphone"


def test_import_skips_files_already_in_v2_vault(client, clean_db, import_dirs):
    from urllib.parse import urlencode
    from import_manager import ImportJob, _run_import

    src, _ = import_dirs
    data = jpeg("vault")
    params = urlencode({
        "source_id": "iphone_test", "original_path": "Camera Roll/v.jpg", "original_filename": "v.jpg",
        "source_location": "Photos", "client_sha256": sha256_hex(data),
    })
    assert client.put("/api/v2/ingest/stream?" + params, content=data).status_code == 200
    _write(os.path.join(src, "IMG_20240201_000000.jpg"), data)

    job = ImportJob(id="test2")
    _run_import(src, job)
    assert job.status == "complete" and job.imported == 0 and job.duplicates_skipped == 1


def test_execute_import_is_atomic(monkeypatch, import_dirs):
    import import_manager

    started = []

    def fake_run(source_dir, job):
        started.append(job.id)  # stays "scanning" = running

    monkeypatch.setattr(import_manager, "_run_import", fake_run)
    monkeypatch.setattr(import_manager, "job_store", import_manager._JobStore())
    job, ok = import_manager.ImportManager.execute_if_idle()
    assert ok
    again, ok2 = import_manager.ImportManager.execute_if_idle()
    assert not ok2 and again.id == job.id


# ── No-overwrite placement (web uploads, imports) ─────────────────────────

@pytest.mark.parametrize("link_errno", [None, "EPERM", "EXDEV"])
def test_claim_unique_path_never_overwrites(tmp_path, monkeypatch, link_errno):
    """link() works / is refused (fs.protected_hardlinks for files owned by another user) /
    crosses filesystems: the file always lands under a free name and nothing is overwritten."""
    import errno
    import storage_engine

    if link_errno:
        def no_link(src, dst):
            raise OSError(getattr(errno, link_errno), link_errno)
        monkeypatch.setattr(storage_engine.os, "link", no_link)
        if link_errno == "EXDEV":
            def no_rename(src, dst):
                raise OSError(errno.EXDEV, "EXDEV")
            monkeypatch.setattr(storage_engine.os, "replace", no_rename)

    dest_dir = tmp_path / "dest"
    dest_dir.mkdir()
    (dest_dir / "IMG_1.jpg").write_bytes(b"existing")
    src = tmp_path / "incoming.jpg"
    src.write_bytes(b"new photo")
    os.utime(src, (1_000_000_000, 1_000_000_000))

    final = storage_engine.claim_unique_path(str(src), str(dest_dir), "IMG_1.jpg")
    assert final == str(dest_dir / "IMG_1_1.jpg")
    assert (dest_dir / "IMG_1.jpg").read_bytes() == b"existing"
    assert (dest_dir / "IMG_1_1.jpg").read_bytes() == b"new photo"
    assert int(os.stat(final).st_mtime) == 1_000_000_000  # dates survive the move
    assert not src.exists()
    assert sorted(p.name for p in dest_dir.iterdir()) == ["IMG_1.jpg", "IMG_1_1.jpg"]
