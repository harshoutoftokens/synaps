"""Maintenance scripts never move/delete v2 vault files, keep DB rows and thumbnails in step,
and refuse to clean the database when the storage disk looks unmounted."""
import importlib.util
import os
import shutil
import sqlite3
import sys
import tempfile
import uuid

import pytest

from conftest import make_jpeg_bytes

BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS_DIR = os.path.join(BACKEND_DIR, "scripts")


@pytest.fixture
def sandbox(storage_root):
    path = os.path.join(storage_root, f"t_maint_{uuid.uuid4().hex[:8]}")
    os.makedirs(path)
    yield path
    shutil.rmtree(path, ignore_errors=True)


def put(path, data=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if data is not None else make_jpeg_bytes() + os.urandom(4))
    return path


def add_media(db, path):
    from models import MediaFile
    from config import STORAGE_PATH

    item = MediaFile(filename=os.path.basename(path), path=path,
                     relative_path=os.path.relpath(path, STORAGE_PATH),
                     directory=os.path.relpath(os.path.dirname(path), STORAGE_PATH),
                     extension=".jpg", media_type="image", is_favorite=True)
    db.add(item)
    db.commit()
    return item.id


def test_vault_protection_reason(storage_root, sandbox, db_session):
    from scanner import vault_protection_reason

    plain = put(os.path.join(sandbox, "plain.jpg"))
    assert vault_protection_reason(plain, db_session) is None
    linked = os.path.join(sandbox, "linked.jpg")
    os.link(plain, linked)
    assert "hardlinked" in vault_protection_reason(linked, db_session)
    canonical = put(os.path.join(storage_root, "Vault", "2031", "01", "0123456789abcdef_IMG.jpg"))
    try:
        assert "canonical" in vault_protection_reason(canonical)
    finally:
        shutil.rmtree(os.path.join(storage_root, "Vault", "2031"), ignore_errors=True)


def test_move_old_media_skips_vault_files_and_keeps_db_and_thumbnails(sandbox, db_session):
    import move_old_media
    from models import MediaFile
    from thumbnails import get_thumbnail_path, ensure_thumbnail_dir

    base = os.path.join(sandbox, "Iphone")
    old = put(os.path.join(base, "2015", "03", "old.jpg"))
    hard = put(os.path.join(base, "2015", "04", "hard.jpg"))
    os.link(hard, os.path.join(sandbox, "elsewhere.jpg"))
    put(os.path.join(base, "2025", "01", "new.jpg"))
    media_id = add_media(db_session, old)
    ensure_thumbnail_dir()
    put(get_thumbnail_path(old), b"thumb")

    dry = move_old_media.move_old_media(base, 2024, dry_run=True)
    assert dry["files_moved"] == 1 and dry["skipped_vault"] == 1 and os.path.exists(old)

    stats = move_old_media.move_old_media(base, 2024, dry_run=False)
    moved = os.path.join(base, "Old_Photos", "old.jpg")
    assert stats["files_moved"] == 1 and stats["skipped_vault"] == 1
    assert os.path.exists(moved) and os.path.exists(hard)
    assert os.path.exists(get_thumbnail_path(moved))
    db_session.expire_all()
    row = db_session.get(MediaFile, media_id)
    assert row.path == moved and row.is_favorite


def test_move_old_media_refuses_vault_root_and_mirrors(storage_root):
    import move_old_media

    assert move_old_media.unsafe_base_reason(os.path.join(storage_root, "Vault"))
    assert move_old_media.unsafe_base_reason(os.path.join(storage_root, "Mirrors", "Harsh"))
    assert move_old_media.unsafe_base_reason(os.path.join(storage_root, "Vault", "Harsh", "Iphone")) is None


def test_organize_skips_vault_files(sandbox, db_session):
    import organize_existing_media
    from models import MediaFile

    flat = os.path.join(sandbox, "Flat")
    dated = put(os.path.join(flat, "IMG_20230415_120000.jpg"))
    hard = put(os.path.join(flat, "IMG_20220101_000000.jpg"))
    os.link(hard, os.path.join(sandbox, "other_link.jpg"))
    media_id = add_media(db_session, dated)

    stats = organize_existing_media.organize(flat, dry_run=False, update_db=True)
    target = os.path.join(flat, "2023", "04", "IMG_20230415_120000.jpg")
    assert stats["moved"] == 1 and stats["skipped_vault"] == 1
    assert os.path.exists(target) and os.path.exists(hard)
    db_session.expire_all()
    assert db_session.get(MediaFile, media_id).path == target


def test_clean_stale_records_refuses_unmounted_storage(db_session, clean_db, monkeypatch):
    import clean_stale_records
    from models import MediaFile

    db_session.add(MediaFile(filename="a.jpg", path="/gone/a.jpg", relative_path="Vault/a.jpg",
                             directory="Vault", extension=".jpg", media_type="image"))
    db_session.commit()
    empty = tempfile.mkdtemp(prefix="synaps-unmounted-")
    try:
        monkeypatch.setattr(clean_stale_records, "STORAGE_PATH", empty)
        clean_stale_records.clean_database(dry_run=False)
    finally:
        shutil.rmtree(empty, ignore_errors=True)
    assert db_session.query(MediaFile).count() == 1


def _load_restructure():
    spec = importlib.util.spec_from_file_location("restructure_nas_mirrors", os.path.join(SCRIPTS_DIR, "restructure_nas_mirrors.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def nas():
    root = tempfile.mkdtemp(prefix="synaps-nas-")
    storage = os.path.join(root, "storage")
    put(os.path.join(storage, "Vault_v2", "2026", "09", "aaaa_new.jpg"), b"new object")
    put(os.path.join(storage, "Vault_v2", "2026", "09", "bbbb_clash.jpg"), b"v2 bytes")
    put(os.path.join(storage, "Vault", "2026", "09", "bbbb_clash.jpg"), b"different bytes")
    put(os.path.join(storage, "Vault", "Harsh", "Mac", "notes.txt"), b"legacy notes")
    put(os.path.join(storage, "Mirrors", "Harsh", "Mac", "notes.txt"), b"other notes")
    put(os.path.join(storage, "Vault", "Harsh", "Mac", "same.txt"), b"same")
    put(os.path.join(storage, "Mirrors", "Harsh", "Mac", "same.txt"), b"same")
    canonical = put(os.path.join(storage, "Vault", "2025", "01", "cccc_IMG.jpg"), b"canonical")
    put(os.path.join(storage, "Mirrors", "mac_harsh", "unique.jpg"), b"only copy")
    os.makedirs(os.path.join(storage, "Mirrors", "mac_harsh", "sub"))
    os.link(canonical, os.path.join(storage, "Mirrors", "mac_harsh", "sub", "link.jpg"))

    db = os.path.join(root, "synaps.db")
    conn = sqlite3.connect(db)
    conn.executescript("""
        CREATE TABLE physical_objects (id TEXT PRIMARY KEY, physical_path TEXT UNIQUE);
        CREATE TABLE logical_items (id TEXT PRIMARY KEY, physical_object_id TEXT, source_id TEXT,
                                    original_path TEXT, original_filename TEXT);
        INSERT INTO physical_objects VALUES ('p1', 'Vault_v2/2026/09/aaaa_new.jpg');
        INSERT INTO physical_objects VALUES ('p2', 'Vault_v2/2026/09/bbbb_clash.jpg');
        INSERT INTO physical_objects VALUES ('p3', 'Vault/2025/01/cccc_IMG.jpg');
        INSERT INTO logical_items VALUES ('l3', 'p3', 'mac_harsh', '/Users/h/Pictures/IMG.jpg', 'IMG.jpg');
    """)
    conn.commit()
    conn.close()
    yield storage, db
    shutil.rmtree(root, ignore_errors=True)


def _run(module, monkeypatch, *args):
    monkeypatch.setattr(sys, "argv", ["restructure_nas_mirrors.py", *args])
    module.main()


def _snapshot(storage):
    out = {}
    for root, _dirs, files in os.walk(storage):
        for f in files:
            p = os.path.join(root, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, storage)] = fh.read()
    return out


def test_restructure_dry_run_changes_nothing(nas, monkeypatch):
    storage, db = nas
    before = _snapshot(storage)
    _run(_load_restructure(), monkeypatch, "--storage-root", storage, "--db", db)
    assert _snapshot(storage) == before
    conn = sqlite3.connect(db)
    assert conn.execute("SELECT physical_path FROM physical_objects WHERE id='p1'").fetchone()[0].startswith("Vault_v2/")
    conn.close()


def test_restructure_execute_never_loses_unique_data(nas, monkeypatch):
    storage, db = nas
    _run(_load_restructure(), monkeypatch, "--storage-root", storage, "--db", db, "--execute", "--yes")
    after = _snapshot(storage)

    # Moved object + DB path updated; the clashing one is kept where it was, row untouched
    assert after["Vault/2026/09/aaaa_new.jpg"] == b"new object"
    assert after["Vault_v2/2026/09/bbbb_clash.jpg"] == b"v2 bytes"
    assert after["Vault/2026/09/bbbb_clash.jpg"] == b"different bytes"
    conn = sqlite3.connect(db)
    paths = dict(conn.execute("SELECT id, physical_path FROM physical_objects"))
    conn.close()
    assert paths["p1"] == "Vault/2026/09/aaaa_new.jpg"
    assert paths["p2"] == "Vault_v2/2026/09/bbbb_clash.jpg"

    # Legacy merge: identical duplicate dropped, differing file kept under another name
    assert after["Mirrors/Harsh/Mac/notes.txt"] == b"other notes"
    assert after["Mirrors/Harsh/Mac/notes (from Vault).txt"] == b"legacy notes"
    assert after["Mirrors/Harsh/Mac/same.txt"] == b"same"
    assert not os.path.exists(os.path.join(storage, "Vault", "Harsh"))

    # Obsolete flat mirror: hardlink removed, unique file kept; the canonical object is intact
    assert after["Mirrors/mac_harsh/unique.jpg"] == b"only copy"
    assert "Mirrors/mac_harsh/sub/link.jpg" not in after
    assert after["Vault/2025/01/cccc_IMG.jpg"] == b"canonical"
    assert after["Mirrors/Harsh/Mac/Pictures/IMG.jpg"] == b"canonical"  # re-created as a hardlink


def test_restructure_refuses_unmounted_storage(monkeypatch, tmp_path):
    module = _load_restructure()
    empty = tmp_path / "storage"
    empty.mkdir()
    db = tmp_path / "x.db"
    db.write_bytes(b"")
    with pytest.raises(SystemExit):
        _run(module, monkeypatch, "--storage-root", str(empty), "--db", str(db), "--execute", "--yes")
