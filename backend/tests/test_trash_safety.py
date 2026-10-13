"""Trash: v2-backed files are refused, restores never overwrite, deletes stay inside the
trash directories, cleanup_expired() keeps its contract, slash-less routes work."""
import os
import shutil
import uuid
from datetime import datetime, timedelta

import pytest

from conftest import make_jpeg_bytes, sha256_hex


@pytest.fixture
def sandbox(storage_root):
    rel = f"t_trash_{uuid.uuid4().hex[:8]}"
    path = os.path.join(storage_root, rel)
    os.makedirs(path)
    yield rel, path
    shutil.rmtree(path, ignore_errors=True)


def _write(path, data=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if data is not None else make_jpeg_bytes())
    return path


def add_media(db, path, **fields):
    from models import MediaFile
    from config import STORAGE_PATH

    values = dict(
        filename=os.path.basename(path), path=path,
        relative_path=os.path.relpath(path, STORAGE_PATH),
        directory=os.path.relpath(os.path.dirname(path), STORAGE_PATH),
        extension=os.path.splitext(path)[1].lower(), media_type="image",
        file_size=os.path.getsize(path) if os.path.exists(path) else 0,
        source="iphone",
    )
    values.update(fields)
    item = MediaFile(**values)
    db.add(item)
    db.commit()
    return item


def test_trash_and_restore_roundtrip(client, sandbox, db_session):
    rel, path = sandbox
    photo = _write(os.path.join(path, "IMG_1.jpg"))
    item = add_media(db_session, photo)

    r = client.post(f"/api/trash/delete/{item.id}")
    assert r.status_code == 200, r.text
    assert not os.path.exists(photo)
    listing = client.get("/api/trash").json()
    entry = next(i for i in listing["items"] if i["filename"] == "IMG_1.jpg")
    assert entry["days_remaining"] in (29, 30)

    r = client.post(f"/api/trash/restore/{entry['id']}")
    assert r.status_code == 200, r.text
    assert os.path.exists(photo)
    assert r.json()["media_id"] and r.json()["restored_filename"] == "IMG_1.jpg"
    from models import MediaFile
    restored = db_session.query(MediaFile).filter(MediaFile.path == photo).one()
    assert restored.source == "unknown"  # re-indexed with a derived source (was left NULL before)


def test_restore_never_overwrites(client, sandbox, db_session):
    rel, path = sandbox
    photo = _write(os.path.join(path, "IMG_2.jpg"), b"original")
    item = add_media(db_session, photo)
    assert client.post(f"/api/trash/delete/{item.id}").status_code == 200
    trash_id = next(i["id"] for i in client.get("/api/trash").json()["items"] if i["filename"] == "IMG_2.jpg")

    _write(photo, b"newer file at the same path")
    r = client.post(f"/api/trash/restore/{trash_id}")
    assert r.status_code == 200, r.text
    assert r.json()["restored_filename"] == "IMG_2 (restored).jpg"
    with open(photo, "rb") as f:
        assert f.read() == b"newer file at the same path"
    with open(os.path.join(path, "IMG_2 (restored).jpg"), "rb") as f:
        assert f.read() == b"original"


def test_same_name_trashed_twice_does_not_collide(client, sandbox, db_session):
    from models import TrashItem

    rel, path = sandbox
    a = add_media(db_session, _write(os.path.join(path, "a", "IMG_3.jpg"), b"first"))
    b = add_media(db_session, _write(os.path.join(path, "b", "IMG_3.jpg"), b"second"))
    assert client.post(f"/api/trash/delete/{a.id}").status_code == 200
    assert client.post(f"/api/trash/delete/{b.id}").status_code == 200
    rows = db_session.query(TrashItem).filter(TrashItem.filename == "IMG_3.jpg").all()
    contents = set()
    for row in rows:
        with open(row.trash_path, "rb") as f:
            contents.add(f.read())
    assert contents == {b"first", b"second"}


def test_canonical_v2_object_is_refused(client, sandbox, db_session, storage_root):
    from models_v2 import PhysicalObject

    data = make_jpeg_bytes(color=(1, 2, 3)) + os.urandom(8)  # unique content -> unique sha256
    sha = sha256_hex(data)
    rel_canonical = f"Vault/2026/10/{sha[:16]}_IMG_0001.jpg"
    canonical = _write(os.path.join(storage_root, rel_canonical), data)
    try:
        db_session.add(PhysicalObject(sha256=sha, file_size=len(data), physical_path=rel_canonical))
        db_session.commit()
        item = add_media(db_session, canonical)
        r = client.post(f"/api/trash/delete/{item.id}")
        assert r.status_code == 409
        assert "vault" in r.json()["detail"].lower()
        assert os.path.exists(canonical)
    finally:
        os.remove(canonical)


def test_hardlinked_symlinked_and_mirror_files_are_refused(client, sandbox, db_session, storage_root):
    rel, path = sandbox
    original = _write(os.path.join(path, "orig.jpg"))
    linked = os.path.join(path, "hardlink.jpg")
    os.link(original, linked)
    symlink = os.path.join(path, "symlink.jpg")
    os.symlink(original, symlink)
    mirror = _write(os.path.join(storage_root, "Mirrors", rel, "m.jpg"))
    try:
        for target in (linked, symlink, mirror):
            item = add_media(db_session, target)
            r = client.post(f"/api/trash/delete/{item.id}")
            assert r.status_code == 409, (target, r.text)
            assert os.path.lexists(target)
    finally:
        shutil.rmtree(os.path.join(storage_root, "Mirrors", rel), ignore_errors=True)


def test_files_outside_storage_are_refused(client, db_session, tmp_path):
    outside = tmp_path / "outside.jpg"
    outside.write_bytes(b"x")
    item = add_media(db_session, str(outside))
    assert client.post(f"/api/trash/delete/{item.id}").status_code == 409
    assert outside.exists()


def test_permanent_delete_only_inside_trash(client, sandbox, db_session):
    from models import TrashItem

    rel, path = sandbox
    victim = _write(os.path.join(path, "precious.jpg"), b"keep me")
    rogue = TrashItem(original_path=victim, trash_path=victim, filename="precious.jpg")
    db_session.add(rogue)
    db_session.commit()
    r = client.delete(f"/api/trash/permanent/{rogue.id}")
    assert r.status_code == 409
    assert os.path.exists(victim)

    item = add_media(db_session, _write(os.path.join(path, "bye.jpg")))
    client.post(f"/api/trash/delete/{item.id}")
    trash_row = db_session.query(TrashItem).filter(TrashItem.filename == "bye.jpg").one()
    assert client.delete(f"/api/trash/permanent/{trash_row.id}").status_code == 200
    assert not os.path.exists(trash_row.trash_path)


def test_cleanup_expired_contract(client, sandbox, db_session):
    """main.py's housekeeping calls cleanup_expired(db) directly and reads result['deleted']."""
    from models import TrashItem
    from routers.trash import cleanup_expired

    rel, path = sandbox
    old = add_media(db_session, _write(os.path.join(path, "old.jpg")))
    fresh = add_media(db_session, _write(os.path.join(path, "fresh.jpg")))
    client.post(f"/api/trash/delete/{old.id}")
    client.post(f"/api/trash/delete/{fresh.id}")
    old_row = db_session.query(TrashItem).filter(TrashItem.filename == "old.jpg").one()
    old_row.auto_delete_at = datetime.now() - timedelta(days=1)
    victim = _write(os.path.join(path, "not-in-trash.jpg"), b"keep")
    rogue = TrashItem(original_path=victim, trash_path=victim, filename="rogue.jpg",
                      auto_delete_at=datetime.now() - timedelta(days=1))
    db_session.add(rogue)
    db_session.commit()
    old_trash_path = old_row.trash_path

    result = cleanup_expired(db_session)
    assert result["status"] == "success"
    assert result["deleted"] >= 1 and result["errors"] >= 1
    assert not os.path.exists(old_trash_path)
    assert os.path.exists(victim)  # never deletes outside the trash directories
    db_session.expire_all()
    assert db_session.query(TrashItem).filter(TrashItem.filename == "fresh.jpg").count() == 1

    db_session.delete(db_session.get(TrashItem, rogue.id))
    db_session.commit()
    assert client.post("/api/trash/cleanup").json()["status"] == "success"


def test_cross_device_trash_goes_to_storage_trash(client, sandbox, db_session, monkeypatch):
    import routers.trash as trash

    rel, path = sandbox
    photo = _write(os.path.join(path, "big.mov"), b"video")
    item = add_media(db_session, photo, media_type="video")
    monkeypatch.setattr(trash, "_trash_dir_for", lambda p: trash.STORAGE_TRASH_DIR)
    assert client.post(f"/api/trash/delete/{item.id}").status_code == 200
    from models import TrashItem
    row = db_session.query(TrashItem).filter(TrashItem.filename == "big.mov").one()
    assert row.trash_path.startswith(trash.STORAGE_TRASH_DIR)
    # hidden from the Finder
    assert client.get("/api/finder/browse", params={"path": ".synaps_trash"}).status_code == 404
    assert client.post(f"/api/trash/restore/{row.id}").status_code == 200
    assert os.path.exists(photo)


def test_trash_thumbnail_placeholder_and_cache(client, sandbox, db_session):
    from models import TrashItem
    from thumbnails import get_thumbnail_path, ensure_thumbnail_dir

    rel, path = sandbox
    row = TrashItem(original_path=os.path.join(path, "x.jpg"), trash_path="/nonexistent", filename="x.jpg")
    db_session.add(row)
    db_session.commit()
    r = client.get(f"/api/trash/thumbnail/{row.id}")
    assert r.status_code == 200 and r.headers["content-type"].startswith("image/svg")

    ensure_thumbnail_dir()
    with open(get_thumbnail_path(row.original_path), "wb") as f:
        f.write(b"RIFFxxxxWEBP")
    r = client.get(f"/api/trash/thumbnail/{row.id}")
    assert r.headers["content-type"] == "image/webp"
    assert client.get(f"/api/trash/thumbnail/{row.id}", headers={"If-None-Match": r.headers["etag"]}).status_code == 304
    assert client.head(f"/api/trash/thumbnail/{row.id}").status_code == 200


@pytest.mark.parametrize("url", ["/api/trash", "/api/trash/"])
def test_trash_listing_without_redirect(client, url):
    r = client.get(url, follow_redirects=False)
    assert r.status_code == 200
    assert "items" in r.json()
