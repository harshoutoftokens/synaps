"""v2 ingest: pre-check, multipart + streamed uploads, dedup, content changes, races, v1 bridge."""
import asyncio
import io
import os
import re
import threading
import time
from datetime import datetime
from urllib.parse import urlencode

import pytest
from fastapi import HTTPException
from sqlalchemy import event

from conftest import make_jpeg_bytes, sha256_hex

MAC = {"id": "mac_test", "friendly_name": "Test Mac", "platform": "macOS"}
IPHONE = {"id": "iphone_test", "friendly_name": "Test iPhone", "platform": "ios"}


def unique_jpeg(tag: str = "") -> bytes:
    """A valid JPEG whose SHA-256 is unique (decoders ignore bytes after the EOI marker)."""
    return make_jpeg_bytes(color=(10, 120, 200)) + os.urandom(16) + tag.encode()


def exif_jpeg(date_str: str) -> bytes:
    from PIL import Image

    img = Image.new("RGB", (32, 24), (5, 6, 7))
    exif = Image.Exif()
    exif[0x0132] = date_str  # DateTime, read by scanner.extract_exif_date via exifread
    buf = io.BytesIO()
    img.save(buf, format="JPEG", exif=exif.tobytes())
    return buf.getvalue() + os.urandom(8)


def check(client, files, source=MAC):
    r = client.post("/api/v2/ingest/check", json={"source": source, "files": files})
    assert r.status_code == 200, r.text
    return r.json()


def check_item(data: bytes, path: str, **extra):
    item = {
        "original_path": path,
        "original_filename": os.path.basename(path),
        "file_size": len(data),
        "source_location": "Pictures",
        "client_sha256": sha256_hex(data),
    }
    item.update(extra)
    return item


def upload_multipart(client, data: bytes, path: str, source_id="mac_test", sha=None, **fields):
    form = {
        "source_id": source_id,
        "original_path": path,
        "original_filename": os.path.basename(path),
        "source_location": "Pictures",
        "client_sha256": sha or sha256_hex(data),
        "is_favorite": "false",
    }
    form.update(fields)
    return client.post(
        "/api/v2/ingest/upload",
        data=form,
        files={"file": (os.path.basename(path), data, "application/octet-stream")},
    )


def stream_params(data: bytes, path: str, source_id="mac_test", sha=None, **extra) -> str:
    params = {
        "source_id": source_id,
        "original_path": path,
        "original_filename": os.path.basename(path),
        "source_location": "Pictures",
        "client_sha256": sha or sha256_hex(data),
    }
    params.update(extra)
    return urlencode(params)


def upload_stream(client, data: bytes, path: str, source_id="mac_test", sha=None, **extra):
    return client.put(
        "/api/v2/ingest/stream?" + stream_params(data, path, source_id, sha, **extra),
        content=data,
        headers={"Content-Type": "application/octet-stream"},
    )


def staging_files(storage_root):
    """Partial uploads left by the ingest pipeline (<uuid hex>.upload[.ext]); other tests may
    park unrelated fixtures in the staging folder."""
    staging = os.path.join(storage_root, ".synaps_tmp")
    names = os.listdir(staging) if os.path.isdir(staging) else []
    return sorted(n for n in names if re.match(r"^[0-9a-f]{32}\.upload", n))


def rows(db, model, **filters):
    db.expire_all()
    return db.query(model).filter_by(**filters).all()


class QueryCounter:
    """Counts SQL statements (total and SELECTs) executed while active."""

    def __init__(self, engine):
        self.engine = engine
        self.count = 0
        self.selects = 0

    def _on_execute(self, conn, cursor, statement, parameters, context, executemany):
        self.count += 1
        if statement.lstrip().upper().startswith(("SELECT", "WITH")):
            self.selects += 1

    def __enter__(self):
        event.listen(self.engine, "before_cursor_execute", self._on_execute)
        return self

    def __exit__(self, *exc):
        event.remove(self.engine, "before_cursor_execute", self._on_execute)


# ── Pre-check + upload + dedup ────────────────────────────────────────────

def test_check_upload_then_dedup(client, clean_db, db_session, storage_root):
    from models_v2 import LogicalItem, PhysicalObject

    data = unique_jpeg()
    path = "/Users/test/Pictures/Trip/IMG_0001.JPG"

    first = check(client, [check_item(data, path)])
    assert first["need_upload"] == 1 and first["dedup_linked"] == 0
    assert first["results"][0]["status"] == "need_upload"

    r = upload_multipart(client, data, path)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "success"
    assert set(body) >= {"physical_object_id", "logical_item_id", "canonical_path", "mirror_path", "sha256"}
    assert body["sha256"] == sha256_hex(data)
    with open(os.path.join(storage_root, body["canonical_path"]), "rb") as f:
        assert f.read() == data
    assert staging_files(storage_root) == []

    again = check(client, [check_item(data, path)])
    assert again["dedup_linked"] == 1 and again["need_upload"] == 0
    assert again["results"][0] == {
        "original_path": path, "status": "dedup_linked", "physical_object_id": body["physical_object_id"],
    }

    # Same content from another path and device: linked with zero transfer
    copy_path = "Camera Roll/IMG_0001.JPG"
    linked = check(client, [check_item(data, copy_path, is_favorite=True)], source=IPHONE)
    assert linked["results"][0]["status"] == "dedup_linked"

    phys = rows(db_session, PhysicalObject, sha256=sha256_hex(data))
    assert len(phys) == 1
    assert phys[0].reference_count == 2
    assert phys[0].metadata_record.is_favorite is True
    assert len(rows(db_session, LogicalItem, physical_object_id=phys[0].id)) == 2

    # The iPhone copy got a hardlink mirror of the canonical file
    mirror = os.path.join(storage_root, "Mirrors", "Harsh", "Iphone", "Camera Roll", "IMG_0001.JPG")
    canonical = os.path.join(storage_root, phys[0].physical_path)
    assert os.stat(mirror).st_ino == os.stat(canonical).st_ino


def test_check_batch_is_not_n_plus_one(client, clean_db):
    from database import engine

    # 40 files already on the NAS, checked from new paths in 4 shared folders
    files = []
    for i in range(40):
        data = unique_jpeg(str(i))
        assert upload_stream(client, data, f"/Users/test/Seed/{i}.jpg").status_code == 200
        files.append(check_item(data, f"/Users/test/Batch/F{i % 4}/{i}.jpg"))
    files += [check_item(unique_jpeg("new"), "/Users/test/Batch/new.jpg")]

    with QueryCounter(engine) as first:
        result = check(client, files)
    assert result["dedup_linked"] == 40 and result["need_upload"] == 1
    # Old code: ~4 lookups per file. Now a few IN queries; the remaining statements are
    # the writes for the 40 new links (node, logical item, reference count).
    assert first.selects <= 10, first.selects

    # Re-checking already linked files (the common case) is a constant number of queries
    with QueryCounter(engine) as again:
        result = check(client, files)
    assert result["dedup_linked"] == 40
    assert again.count <= 10, again.count


def test_check_repoints_path_whose_content_changed_to_known_content(client, clean_db, db_session):
    from models_v2 import LogicalItem, PhysicalObject

    a, b = unique_jpeg("a"), unique_jpeg("b")
    assert upload_stream(client, a, "/Users/test/x/a.jpg").status_code == 200
    assert upload_stream(client, b, "/Users/test/x/b.jpg").status_code == 200

    # a.jpg was overwritten on the Mac with b's bytes
    check(client, [check_item(b, "/Users/test/x/a.jpg")])
    phys_a = rows(db_session, PhysicalObject, sha256=sha256_hex(a))[0]
    phys_b = rows(db_session, PhysicalObject, sha256=sha256_hex(b))[0]
    logical = rows(db_session, LogicalItem, original_path="/Users/test/x/a.jpg")[0]
    assert logical.physical_object_id == phys_b.id
    assert logical.node.physical_object_id == phys_b.id
    assert phys_a.reference_count == 0
    assert phys_b.reference_count == 2


# ── Streamed upload ───────────────────────────────────────────────────────

def test_stream_upload_happy_path(client, clean_db, db_session, storage_root):
    from models import MediaFile
    from models_v2 import FilesystemNode, LogicalItem, MediaMetadata, PhysicalObject

    data = unique_jpeg()
    path = "/Users/test/Pictures/IMG_0002.JPG"
    r = upload_stream(client, data, path, is_favorite="true",
                      source_created_at="2020-02-15T08:00:00Z", source_modified_at="2020-02-16T08:00:00Z")
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["status"] == "success" and body["sha256"] == sha256_hex(data)
    assert set(body) == {"status", "physical_object_id", "logical_item_id", "canonical_path", "mirror_path", "sha256"}

    canonical = os.path.join(storage_root, body["canonical_path"])
    with open(canonical, "rb") as f:
        assert f.read() == data
    assert body["canonical_path"].startswith(os.path.join("Vault", "2020", "02"))
    assert os.path.basename(canonical) == sha256_hex(data)[:16] + "_IMG_0002.JPG"
    assert staging_files(storage_root) == []

    mirror = body["mirror_path"]
    assert os.path.realpath(mirror).startswith(os.path.realpath(os.path.join(storage_root, "Mirrors")))
    assert mirror.endswith(os.path.join("Harsh", "Mac", "Pictures", "IMG_0002.JPG"))
    assert os.stat(mirror).st_ino == os.stat(canonical).st_ino

    phys = rows(db_session, PhysicalObject, id=body["physical_object_id"])[0]
    assert phys.reference_count == 1 and phys.mime_type == "image/jpeg"
    meta = rows(db_session, MediaMetadata, physical_object_id=phys.id)[0]
    assert meta.is_favorite is True and meta.media_type == "image"
    logical = rows(db_session, LogicalItem, id=body["logical_item_id"])[0]
    assert logical.source_created_at == datetime(2020, 2, 15, 8, 0, 0)  # stored as UTC wall clock
    leaf = rows(db_session, FilesystemNode, id=logical.node_id)[0]
    assert leaf.name == "IMG_0002.JPG" and leaf.physical_object_id == phys.id and not leaf.is_directory

    media = rows(db_session, MediaFile, path=canonical)
    assert len(media) == 1
    assert media[0].source == "mac" and media[0].content_hash == sha256_hex(data)
    assert media[0].filename == "IMG_0002.JPG" and media[0].is_favorite is True
    assert media[0].relative_path == body["canonical_path"]


def test_stream_and_multipart_share_response_shape(client, clean_db):
    a, b = unique_jpeg("a"), unique_jpeg("b")
    ra = upload_multipart(client, a, "/Users/test/s/a.jpg")
    rb = upload_stream(client, b, "/Users/test/s/b.jpg")
    assert ra.status_code == rb.status_code == 200
    assert set(ra.json()) == set(rb.json())


def test_stream_sha_mismatch_is_400_and_leaves_nothing(client, clean_db, db_session, storage_root):
    from models_v2 import PhysicalObject

    data = unique_jpeg()
    wrong = sha256_hex(b"something else")
    r = upload_stream(client, data, "/Users/test/bad.jpg", sha=wrong)
    assert r.status_code == 400
    assert "SHA-256 mismatch" in r.json()["detail"]
    assert staging_files(storage_root) == []
    assert rows(db_session, PhysicalObject) == []

    r = upload_multipart(client, data, "/Users/test/bad.jpg", sha=wrong)
    assert r.status_code == 400
    assert staging_files(storage_root) == []


def test_stream_requires_content_length(client, clean_db, storage_root):
    data = unique_jpeg()
    r = client.put(
        "/api/v2/ingest/stream?" + stream_params(data, "/Users/test/chunked.jpg"),
        content=iter([data[:10], data[10:]]),  # chunked transfer encoding, no Content-Length
        headers={"Content-Type": "application/octet-stream"},
    )
    assert r.status_code == 411
    assert staging_files(storage_root) == []


def test_stream_rejects_malformed_sha_before_reading(client, clean_db, storage_root):
    data = unique_jpeg()
    r = upload_stream(client, data, "/Users/test/x.jpg", sha="not-a-sha")
    assert r.status_code == 400
    assert staging_files(storage_root) == []


def test_stream_missing_params_is_422(client):
    r = client.put("/api/v2/ingest/stream?source_id=x", content=b"abc")
    assert r.status_code == 422


def test_stream_refuses_when_disk_would_fill(client, clean_db, storage_root, monkeypatch):
    import routers.ingest_v2 as ingest

    monkeypatch.setattr(ingest, "MIN_FREE_BYTES", 1 << 62)
    r = upload_stream(client, unique_jpeg(), "/Users/test/big.jpg")
    assert r.status_code == 507
    assert staging_files(storage_root) == []


def test_client_disconnect_cleans_up_staging(app, clean_db, storage_root):
    from starlette.requests import Request
    from routers.ingest_v2 import upload_stream_v2

    data = unique_jpeg()
    messages = [
        {"type": "http.request", "body": data[:100], "more_body": True},
        {"type": "http.disconnect"},
    ]

    async def receive():
        return messages.pop(0)

    scope = {
        "type": "http", "method": "PUT", "path": "/api/v2/ingest/stream", "query_string": b"",
        "headers": [(b"content-length", str(len(data)).encode())],
    }

    async def run():
        return await upload_stream_v2(
            Request(scope, receive), source_id="mac_test", original_path="/Users/test/gone.jpg",
            original_filename="gone.jpg", source_location="Pictures", client_sha256=sha256_hex(data),
            source_created_at=None, source_modified_at=None, is_favorite=False,
        )

    with pytest.raises(HTTPException) as exc:
        asyncio.run(run())
    assert exc.value.status_code == 400
    assert staging_files(storage_root) == []


def test_failure_after_staging_cleans_up(client, clean_db, storage_root, monkeypatch):
    import routers.ingest_v2 as ingest

    def boom(*args, **kwargs):
        raise RuntimeError("db exploded")

    monkeypatch.setattr(ingest, "_commit_ingest", boom)
    with pytest.raises(RuntimeError):
        upload_stream(client, unique_jpeg(), "/Users/test/boom.jpg")
    with pytest.raises(RuntimeError):
        upload_multipart(client, unique_jpeg(), "/Users/test/boom2.jpg")
    assert staging_files(storage_root) == []


# ── Content changes, reference counts, v1 bridge ──────────────────────────

def test_content_change_at_same_path_repoints_node_and_counts(client, clean_db, db_session, storage_root):
    from models import MediaFile
    from models_v2 import LogicalItem, PhysicalObject

    path = "/Users/test/Docs/photo.jpg"
    v1, v2 = unique_jpeg("v1"), unique_jpeg("v2")

    r1 = upload_stream(client, v1, path)
    assert r1.status_code == 200
    # Re-uploading the same file at the same path changes nothing
    assert upload_multipart(client, v1, path).status_code == 200
    phys1 = rows(db_session, PhysicalObject, sha256=sha256_hex(v1))[0]
    assert phys1.reference_count == 1

    r2 = upload_stream(client, v2, path)
    assert r2.status_code == 200
    assert r2.json()["logical_item_id"] == r1.json()["logical_item_id"]

    phys1 = rows(db_session, PhysicalObject, sha256=sha256_hex(v1))[0]
    phys2 = rows(db_session, PhysicalObject, sha256=sha256_hex(v2))[0]
    assert phys1.reference_count == 0
    assert phys2.reference_count == 1
    logicals = rows(db_session, LogicalItem, source_id="mac_test", original_path=path)
    assert len(logicals) == 1
    assert logicals[0].physical_object_id == phys2.id
    assert logicals[0].node.physical_object_id == phys2.id  # the tree shows the new content

    tree = client.get("/api/v2/sources/mac_test/tree", params={"parent_id": logicals[0].node.parent_id}).json()
    assert [f["sha256"] for f in tree["files"]] == [sha256_hex(v2)]

    # Mirror now points at the new content; both versions stay in the Vault and timeline
    mirror = r2.json()["mirror_path"]
    assert os.stat(mirror).st_ino == os.stat(os.path.join(storage_root, phys2.physical_path)).st_ino
    assert os.path.exists(os.path.join(storage_root, phys1.physical_path))
    assert len(rows(db_session, MediaFile)) == 2

    # And back again: v1 content is re-linked, counts stay exact
    assert upload_stream(client, v1, path).status_code == 200
    phys1 = rows(db_session, PhysicalObject, sha256=sha256_hex(v1))[0]
    phys2 = rows(db_session, PhysicalObject, sha256=sha256_hex(v2))[0]
    assert (phys1.reference_count, phys2.reference_count) == (1, 0)


def test_v2_ingest_creates_exactly_one_media_file_row(client, clean_db, db_session, storage_root):
    from models import MediaFile

    data = unique_jpeg()
    body = upload_stream(client, data, "ph://ABC-123/L0/001/IMG_0003.JPG", source_id="iphone_test").json()
    # same content again from another device and path
    assert upload_stream(client, data, "/Users/test/IMG_0003.JPG").status_code == 200
    check(client, [check_item(data, "/Users/test/elsewhere/IMG_0003.JPG")])

    canonical = os.path.join(storage_root, body["canonical_path"])
    media = rows(db_session, MediaFile)
    assert [m.path for m in media] == [canonical]
    assert media[0].source == "iphone"
    assert not any("Mirrors" in m.path for m in media)

    # A manual rescan must not index the file a second time, nor its mirrors or partial uploads
    # (it may index canonical files that earlier tests left on disk)
    os.makedirs(os.path.join(storage_root, ".synaps_tmp"), exist_ok=True)
    with open(os.path.join(storage_root, ".synaps_tmp", "partial.upload.jpg"), "wb") as f:
        f.write(data)
    try:
        from scanner import scan_directory
        scan_directory(db_session)
    finally:
        os.remove(os.path.join(storage_root, ".synaps_tmp", "partial.upload.jpg"))
    paths = [m.path for m in rows(db_session, MediaFile)]
    assert paths.count(canonical) == 1
    assert not [p for p in paths if os.sep + "Mirrors" + os.sep in p or ".synaps_tmp" in p]
    rows(db_session, MediaFile)  # refresh
    media = rows(db_session, MediaFile, path=canonical)

    # and the web endpoints serve it
    r = client.get(f"/api/media/file/{media[0].id}")
    assert r.status_code == 200 and r.content == data


def test_v2_non_media_file_gets_no_timeline_row(client, clean_db, db_session):
    from models import MediaFile

    data = b"%PDF-1.4 not really" + os.urandom(8)
    assert upload_stream(client, data, "/Users/test/Downloads/doc.pdf").status_code == 200
    assert rows(db_session, MediaFile) == []


def test_exif_date_decides_vault_folder_and_timeline_date(client, clean_db, db_session):
    from models import MediaFile

    data = exif_jpeg("2021:07:04 12:34:56")
    body = upload_stream(client, data, "/Users/test/Pictures/holiday.jpg",
                         source_created_at="2023-01-01T00:00:00Z").json()
    assert body["canonical_path"].startswith(os.path.join("Vault", "2021", "07"))
    media = rows(db_session, MediaFile)[0]
    assert media.date_taken == datetime(2021, 7, 4, 12, 34, 56)


def test_source_creation_date_used_without_exif(client, clean_db):
    body = upload_stream(client, unique_jpeg(), "/Users/test/Pictures/noexif.jpg",
                         source_created_at="2019-03-14T12:00:00Z").json()
    assert body["canonical_path"].startswith(os.path.join("Vault", "2019", "03"))


def test_multipart_iso_z_dates_parsed(client, clean_db, db_session):
    from models_v2 import LogicalItem

    r = upload_multipart(client, unique_jpeg(), "/Users/test/z.jpg",
                         source_created_at="2022-06-10T10:00:00Z", source_modified_at="2022-06-11T10:00:00Z")
    assert r.status_code == 200
    logical = rows(db_session, LogicalItem, id=r.json()["logical_item_id"])[0]
    assert logical.source_modified_at == datetime(2022, 6, 11, 10, 0, 0)


# ── Concurrency ───────────────────────────────────────────────────────────

def _parallel(n, fn):
    barrier = threading.Barrier(n)
    results = [None] * n

    def run(i):
        barrier.wait()
        results[i] = fn(i)

    threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join(60)
    return results


def test_concurrent_identical_uploads_do_not_500(client, clean_db, db_session, storage_root):
    from models import MediaFile
    from models_v2 import FilesystemNode, LogicalItem, PhysicalObject

    data = unique_jpeg()
    n = 8
    responses = _parallel(n, lambda i: (upload_stream if i % 2 else upload_multipart)(
        client, data, f"/Users/test/Race/copy{i}.jpg"))
    assert [r.status_code for r in responses] == [200] * n, [r.text for r in responses]

    phys = rows(db_session, PhysicalObject)
    assert len(phys) == 1 and phys[0].reference_count == n
    assert len(rows(db_session, LogicalItem)) == n
    assert len(rows(db_session, MediaFile)) == 1
    # one "Race" folder, not one per request
    assert len(rows(db_session, FilesystemNode, name="Race")) == 1
    assert staging_files(storage_root) == []
    vault_files = [f for _, _, fs in os.walk(os.path.join(storage_root, "Vault")) for f in fs
                   if f.startswith(sha256_hex(data)[:16])]
    assert len(vault_files) == 1


@pytest.mark.parametrize("source_id,path", [
    ("mac_test", "/Users/test/Same/one.jpg"),
    # top-level entry: NULL parent_id, which the unique node index cannot protect
    ("iphone_test", "IMG_ROOT.JPG"),
])
def test_concurrent_uploads_of_same_path(client, clean_db, db_session, source_id, path):
    from models_v2 import FilesystemNode, LogicalItem, PhysicalObject

    data = unique_jpeg()
    # content and source already on the NAS: no SHA-256 / source insert conflict forces a retry
    assert upload_stream(client, data, "seed.jpg", source_id=source_id).status_code == 200
    responses = _parallel(6, lambda i: upload_stream(client, data, path, source_id=source_id))
    assert all(r.status_code == 200 for r in responses)
    assert len(rows(db_session, LogicalItem, source_id=source_id, original_path=path)) == 1
    assert len(rows(db_session, FilesystemNode, name=os.path.basename(path))) == 1
    assert rows(db_session, PhysicalObject)[0].reference_count == 2


def test_integrity_race_with_another_process_is_retried(client, clean_db, db_session, storage_root, monkeypatch):
    """Another worker process inserts the same SHA-256 between our check and insert."""
    import routers.ingest_v2 as ingest
    from database import SessionLocal
    from models_v2 import PhysicalObject

    data = unique_jpeg()
    sha = sha256_hex(data)
    winner_rel = os.path.join("Vault", "2001", "01", f"{sha[:16]}_winner.jpg")
    original = ingest._get_or_register_source
    state = {"done": False}

    def racing_source(db, source_id):
        if not state["done"]:
            state["done"] = True
            os.makedirs(os.path.join(storage_root, "Vault", "2001", "01"), exist_ok=True)
            with open(os.path.join(storage_root, winner_rel), "wb") as f:
                f.write(data)
            with SessionLocal() as other:
                other.add(PhysicalObject(sha256=sha, file_size=len(data), physical_path=winner_rel, reference_count=0))
                other.commit()
        return original(db, source_id)

    monkeypatch.setattr(ingest, "_get_or_register_source", racing_source)
    r = upload_stream(client, data, "/Users/test/raced.jpg")
    assert r.status_code == 200, r.text
    assert r.json()["canonical_path"] == winner_rel
    phys = rows(db_session, PhysicalObject)
    assert len(phys) == 1 and phys[0].reference_count == 1
    # our own copy (moved into the Vault before the conflict) was removed again
    ours = [f for _, _, fs in os.walk(os.path.join(storage_root, "Vault")) for f in fs if f.startswith(sha[:16])]
    assert ours == [os.path.basename(winner_rel)]


def test_upload_does_not_block_the_event_loop(client, clean_db, monkeypatch):
    """Slow ingest work (EXIF, ffprobe, disk) must run off the event loop."""
    import routers.ingest_v2 as ingest

    started = threading.Event()
    real = ingest._resolve_capture_date

    def slow(*args, **kwargs):
        started.set()
        time.sleep(1.5)
        return real(*args, **kwargs)

    monkeypatch.setattr(ingest, "_resolve_capture_date", slow)
    for upload in (upload_stream, upload_multipart):
        started.clear()
        worker = threading.Thread(target=upload, args=(client, unique_jpeg(), f"/Users/test/slow_{upload.__name__}.jpg"))
        worker.start()
        assert started.wait(10)
        t0 = time.monotonic()
        assert client.get("/api/health").status_code == 200
        assert time.monotonic() - t0 < 0.75
        worker.join(30)


# ── Mirrors: path traversal ───────────────────────────────────────────────

def _inside(path, root):
    return os.path.realpath(path).startswith(os.path.realpath(root) + os.sep)


@pytest.mark.parametrize("platform,original_path", [
    ("macOS", "/Users/test/../../../victim.jpg"),
    ("macOS", "/Users/test/Pictures/../../../../../../victim.jpg"),
    ("Windows", "C:\\..\\..\\..\\victim.jpg"),
    ("Windows", "..\\..\\..\\victim.jpg"),
    ("iOS", "/../../victim.jpg"),
    ("iOS", "../../../victim.jpg"),
])
def test_mirror_never_escapes_mirrors_root(storage_root, platform, original_path):
    from storage_engine import create_hardlink_mirror

    vault_dir = os.path.join(storage_root, "Vault", "1999", "09")
    os.makedirs(vault_dir, exist_ok=True)
    phys = os.path.join(vault_dir, "deadbeefdeadbeef_victim.jpg")
    with open(phys, "wb") as f:
        f.write(b"canonical")
    victim = os.path.join(storage_root, "victim.jpg")
    with open(victim, "wb") as f:
        f.write(b"precious")

    mirror = create_hardlink_mirror(phys, "Test Device", original_path, platform)
    mirrors_root = os.path.join(storage_root, "Mirrors")
    assert mirror is None or _inside(mirror, mirrors_root)
    with open(victim, "rb") as f:
        assert f.read() == b"precious"
    assert not os.path.islink(victim)


def test_mirror_absolute_paths_stay_inside(storage_root):
    from storage_engine import create_hardlink_mirror

    phys = os.path.join(storage_root, "Vault", "abs_source.jpg")
    os.makedirs(os.path.dirname(phys), exist_ok=True)
    with open(phys, "wb") as f:
        f.write(b"x")
    for platform, path in [("iOS", "/etc/passwd"), ("Windows", "D:/Windows/system.ini"), ("macOS", "/private/etc/hosts")]:
        mirror = create_hardlink_mirror(phys, "Harsh's Device", path, platform)
        assert mirror is not None and _inside(mirror, os.path.join(storage_root, "Mirrors"))


def test_mirror_source_name_dotdot_is_sanitized(storage_root):
    from storage_engine import create_hardlink_mirror

    phys = os.path.join(storage_root, "Vault", "dotdot_source.jpg")
    os.makedirs(os.path.dirname(phys), exist_ok=True)
    with open(phys, "wb") as f:
        f.write(b"x")
    mirror = create_hardlink_mirror(phys, "..", "Vault/dotdot_source.jpg", "unknown")
    assert mirror is not None and _inside(mirror, os.path.join(storage_root, "Mirrors"))
    with open(phys, "rb") as f:
        assert f.read() == b"x"


def test_mirror_does_not_follow_symlinked_folder_out(storage_root, tmp_path):
    from storage_engine import create_hardlink_mirror

    outside = tmp_path / "outside"
    outside.mkdir()
    link_parent = os.path.join(storage_root, "Mirrors", "Harsh", "Mac")
    os.makedirs(link_parent, exist_ok=True)
    link = os.path.join(link_parent, "Escape")
    if not os.path.lexists(link):
        os.symlink(str(outside), link)
    phys = os.path.join(storage_root, "Vault", "symlink_source.jpg")
    os.makedirs(os.path.dirname(phys), exist_ok=True)
    with open(phys, "wb") as f:
        f.write(b"x")

    assert create_hardlink_mirror(phys, "mac_test", "/Users/test/Escape/sub/file.jpg", "macOS") is None
    assert list(outside.iterdir()) == []


def test_upload_with_traversal_path_stays_inside(client, clean_db, storage_root):
    victim = os.path.join(storage_root, "victim2.jpg")
    with open(victim, "wb") as f:
        f.write(b"precious")
    r = upload_stream(client, unique_jpeg(), "/Users/test/../../../victim2.jpg")
    assert r.status_code == 200
    assert r.json()["mirror_path"] is None or _inside(r.json()["mirror_path"], os.path.join(storage_root, "Mirrors"))
    with open(victim, "rb") as f:
        assert f.read() == b"precious"


def test_mirror_replaces_stale_link_atomically(storage_root):
    from storage_engine import create_hardlink_mirror

    vault = os.path.join(storage_root, "Vault", "atomic")
    os.makedirs(vault, exist_ok=True)
    old, new = os.path.join(vault, "old.jpg"), os.path.join(vault, "new.jpg")
    for p, content in ((old, b"old"), (new, b"new")):
        with open(p, "wb") as f:
            f.write(content)
    m1 = create_hardlink_mirror(old, "mac_test", "/Users/t/atomic/pic.jpg", "macOS")
    m2 = create_hardlink_mirror(new, "mac_test", "/Users/t/atomic/pic.jpg", "macOS")
    assert m1 == m2
    with open(m2, "rb") as f:
        assert f.read() == b"new"
    assert not [n for n in os.listdir(os.path.dirname(m2)) if n.endswith(".synaps-link")]


# ── Browsing APIs ─────────────────────────────────────────────────────────

def test_tree_sources_and_albums(client, clean_db):
    from database import engine

    paths = ["/Users/test/Pictures/Trip/a.jpg", "/Users/test/Pictures/Trip/b.jpg",
             "/Users/test/Pictures/c.jpg", "/Users/test/Pictures/Trip/Day2/d.jpg"]
    for p in paths:
        assert upload_stream(client, unique_jpeg(p), p).status_code == 200

    sources = {s["id"]: s for s in client.get("/api/v2/sources").json()["sources"]}
    assert sources["mac_test"]["total_items"] == 4

    root = client.get("/api/v2/sources/mac_test/tree").json()
    assert [f["name"] for f in root["folders"]] == ["Pictures"]
    pictures = root["folders"][0]
    assert pictures["children_count"] == 2  # Trip/ and c.jpg

    level = client.get("/api/v2/sources/mac_test/tree", params={"parent_id": pictures["id"]}).json()
    assert [f["name"] for f in level["folders"]] == ["Trip"]
    assert [f["name"] for f in level["files"]] == ["c.jpg"]
    trip_id = level["folders"][0]["id"]
    assert level["folders"][0]["children_count"] == 3

    with QueryCounter(engine) as counter:
        trip = client.get("/api/v2/sources/mac_test/tree", params={"parent_id": trip_id}).json()
    assert [b["name"] for b in trip["breadcrumbs"]] == ["Test Mac", "Pictures", "Trip"] or \
        [b["name"] for b in trip["breadcrumbs"]][1:] == ["Pictures", "Trip"]
    assert [f["name"] for f in trip["files"]] == ["a.jpg", "b.jpg"]
    assert all(f["sha256"] and f["logical_item_id"] and f["media_type"] == "image" for f in trip["files"])
    assert counter.count <= 10, counter.count

    r = client.post("/api/v2/ingest/albums", json={
        "source_id": "mac_test", "album_name": "Trip", "original_paths": paths[:2] + paths[:1] + ["/nope.jpg"],
    })
    assert r.status_code == 200 and r.json()["newly_linked_items"] == 2
    # the Mac app's path for the same endpoint
    r = client.post("/api/v2/ingest/sync-albums", json={
        "source_id": "mac_test", "album_name": "Trip", "original_paths": paths,
    })
    assert r.status_code == 200 and r.json()["newly_linked_items"] == 2

    albums = client.get("/api/v2/albums").json()["albums"]
    assert len(albums) == 1 and albums[0]["item_count"] == 4 and albums[0]["cover_physical_id"]
    items = client.get(f"/api/v2/albums/{albums[0]['id']}").json()
    assert items["total_items"] == 4 and items["album"]["item_count"] == 4

    assert client.post("/api/v2/ingest/albums", json={
        "source_id": "nope", "album_name": "x", "original_paths": []}).status_code == 404


# ── Helpers ───────────────────────────────────────────────────────────────

def test_iso_parsing_handles_z_suffix():
    from routers.ingest_v2 import _naive_utc, _parse_iso

    assert _naive_utc(_parse_iso("2024-05-01T10:20:30Z")) == datetime(2024, 5, 1, 10, 20, 30)
    assert _naive_utc(_parse_iso("2024-05-01T15:50:30+05:30")) == datetime(2024, 5, 1, 10, 20, 30)
    assert _parse_iso("2024-05-01T10:20:30.123456") == datetime(2024, 5, 1, 10, 20, 30, 123456)
    assert _parse_iso("garbage") is None and _parse_iso("") is None and _parse_iso(None) is None


def test_v1_source_key():
    from routers.ingest_v2 import v1_source_key

    assert v1_source_key("iphone_harsh", "ios") == "iphone"
    assert v1_source_key("mac_harsh", "macOS") == "mac"
    assert v1_source_key("mac_studios", "macOS") == "mac"
    assert v1_source_key("win_laptop_hp", "Windows") == "windows"
    assert v1_source_key("iphone_harsh", "") == "iphone"
    assert v1_source_key("gdrive_harsh", "cloud") == "gdrive_harsh"
