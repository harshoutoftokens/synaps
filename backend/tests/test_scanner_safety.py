"""Scanner: component-wise exclusions, hidden/Mirrors skipping, source derivation, no
clobbering on rescan, concurrent-insert tolerance and a GC that never wipes an unmounted disk."""
import os
import shutil
import tempfile
import uuid

import pytest

from conftest import make_jpeg_bytes

import scanner


@pytest.fixture
def storage(monkeypatch, clean_db):
    """A private storage root for the scanner (the shared one is used by other tests)."""
    root = tempfile.mkdtemp(prefix="synaps-scan-")
    monkeypatch.setattr(scanner, "STORAGE_PATH", root)
    monkeypatch.setattr(scanner, "ALLOWED_SCAN_PATHS", [root])
    yield root
    shutil.rmtree(root, ignore_errors=True)


def put(root, rel, data=None):
    path = os.path.join(root, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if data is not None else make_jpeg_bytes() + os.urandom(4))
    return path


def indexed(db):
    from models import MediaFile
    db.expire_all()
    return {m.relative_path: m for m in db.query(MediaFile).all()}


@pytest.fixture
def default_exclusions(monkeypatch):
    # Independent of SYNAPS_OWNER_NAME / SYNAPS_EXCLUDED_PATHS in a local .env
    monkeypatch.setattr(scanner, "NORMALIZED_EXCLUDED_PATHS", scanner._normalize_excluded(
        ["Vault/Windows_laptop-HP", "Vault/Harsh/Mac/Private", *scanner._BUILTIN_EXCLUDED_PATHS]))


def test_excluded_paths_match_whole_components(default_exclusions):
    assert scanner.is_excluded_path("Mirrors")
    assert scanner.is_excluded_path("Mirrors/Harsh/Mac/a.jpg")
    assert scanner.is_excluded_path(".synaps_tmp/abc.upload")
    assert scanner.is_excluded_path("Vault/Harsh/Mac/Private/secret.jpg")
    assert not scanner.is_excluded_path("Vault/Harsh/Mac/PrivateTrip/beach.jpg")
    assert not scanner.is_excluded_path("MirrorsBackup/a.jpg")
    assert not scanner.is_excluded_path("Vault/2026/09/abcd_IMG.jpg")
    assert scanner._normalize_excluded(["", ".", "/Mirrors/", "Mirrors"]) == ["Mirrors"]


def test_scan_skips_excluded_hidden_and_mirrors(storage, db_session, default_exclusions):
    put(storage, "Vault/Harsh/Iphone/2025/IMG_1.jpg")
    put(storage, "Vault/Harsh/Mac/PrivateTrip/IMG_2.jpg")
    put(storage, "Vault/Harsh/Mac/Private/IMG_3.jpg")
    put(storage, "Mirrors/Harsh/Mac/Pictures/IMG_4.jpg")
    put(storage, ".synaps_tmp/IMG_5.jpg")
    put(storage, "Vault/.hidden/IMG_6.jpg")
    put(storage, "Vault/Harsh/Iphone/notes.txt", b"text")

    stats = scanner.scan_directory(db_session)
    assert set(indexed(db_session)) == {"Vault/Harsh/Iphone/2025/IMG_1.jpg", "Vault/Harsh/Mac/PrivateTrip/IMG_2.jpg"}
    assert stats["new"] == 2 and stats["errors"] == 0


def test_source_derivation(storage, db_session):
    from models_v2 import Source, PhysicalObject, LogicalItem

    assert scanner.derive_source("Vault/Harsh/Iphone/2024/IMG.jpg") == "iphone"
    assert scanner.derive_source("Vault/Harsh/Mac/Desktop/a.png") == "mac"
    assert scanner.derive_source("Vault/Windows_laptop-HP/a.jpg") == "windows"
    assert scanner.derive_source("Vault/Harsh/IMG.jpg") == "unknown"       # was "img.jpg"
    assert scanner.derive_source("Imports/x.jpg") == "unknown"
    assert scanner.derive_source("Vault/2026/09/0123456789abcdef_IMG.jpg") == "unknown"  # was "09"

    sid = f"iphone_{uuid.uuid4().hex[:6]}"
    rel = "Vault/2026/09/fedcba9876543210_IMG_7.HEIC"
    db_session.add(Source(id=sid, friendly_name="Harsh's iPhone", platform="iOS"))
    po = PhysicalObject(sha256=uuid.uuid4().hex * 2, file_size=1, physical_path=rel)
    db_session.add(po)
    db_session.flush()
    db_session.add(LogicalItem(physical_object_id=po.id, source_id=sid, original_path="Camera Roll/IMG_7.HEIC",
                               original_filename="IMG_7.HEIC", source_location="Photos"))
    db_session.commit()
    assert scanner.derive_source(rel, db_session) == "iphone"
    assert scanner._platform_source("macOS", "mac_harsh") == "mac"
    assert scanner._platform_source("Windows", "win_pc") == "windows"


def test_rescan_keeps_existing_source_and_favorites(storage, db_session):
    path = put(storage, "Vault/Harsh/Iphone/IMG_8.jpg")
    scanner.scan_directory(db_session)
    row = indexed(db_session)["Vault/Harsh/Iphone/IMG_8.jpg"]
    assert row.source == "iphone"
    row.source = "mac"          # e.g. set by the v2 ingest upsert
    row.is_favorite = True
    db_session.commit()

    scanner.scan_directory(db_session)
    with open(path, "ab") as f:
        f.write(b"grown")
    stats = scanner.scan_directory(db_session, force_rescan=True)  # used to crash on the unique path
    assert stats["updated"] == 1 and stats["errors"] == 0
    row = indexed(db_session)["Vault/Harsh/Iphone/IMG_8.jpg"]
    assert row.source == "mac" and row.is_favorite
    assert row.file_size == os.path.getsize(path)


def test_concurrent_insert_does_not_abort_the_scan(storage, db_session):
    from models import MediaFile

    a = put(storage, "Vault/Harsh/Iphone/A.jpg")
    put(storage, "Vault/Harsh/Iphone/B.jpg")
    batch = [scanner._build_media_file(a, os.path.dirname(a), "A.jpg", ".jpg", db_session)]
    db_session.add(MediaFile(filename="A.jpg", path=a, relative_path="Vault/Harsh/Iphone/A.jpg",
                             directory="Vault/Harsh/Iphone", extension=".jpg", media_type="image", source="mac"))
    db_session.commit()
    stats = {"new": 1, "skipped": 0, "errors": 0}
    scanner._commit_batch(db_session, batch, stats)    # duplicate path: kept theirs, no exception
    assert stats == {"new": 0, "skipped": 1, "errors": 0}
    assert indexed(db_session)["Vault/Harsh/Iphone/A.jpg"].source == "mac"
    scanner.scan_directory(db_session)
    assert "Vault/Harsh/Iphone/B.jpg" in indexed(db_session)


def _orphans(db, root, n, top="Vault"):
    from models import MediaFile
    for i in range(n):
        rel = f"{top}/Harsh/Iphone/gone_{uuid.uuid4().hex[:6]}_{i}.jpg"
        db.add(MediaFile(filename=f"gone_{i}.jpg", path=os.path.join(root, rel), relative_path=rel,
                         directory=os.path.dirname(rel), extension=".jpg", media_type="image"))
    db.commit()


def test_gc_removes_deleted_files(storage, db_session):
    put(storage, "Vault/Harsh/Iphone/keep.jpg")
    scanner.scan_directory(db_session)
    _orphans(db_session, storage, 2)
    stats = scanner.scan_directory(db_session)
    assert stats["stale_deleted"] == 2
    assert set(indexed(db_session)) == {"Vault/Harsh/Iphone/keep.jpg"}


def test_gc_skips_unmounted_storage(storage, db_session, monkeypatch):
    _orphans(db_session, storage, 3)
    empty_mountpoint = tempfile.mkdtemp(prefix="synaps-unmounted-")
    try:
        monkeypatch.setattr(scanner, "STORAGE_PATH", empty_mountpoint)
        monkeypatch.setattr(scanner, "ALLOWED_SCAN_PATHS", [empty_mountpoint])
        stats = scanner.scan_directory(db_session)
        assert stats["gc_skipped"] == "storage_unavailable" and stats["stale_deleted"] == 0
        monkeypatch.setattr(scanner, "STORAGE_PATH", os.path.join(empty_mountpoint, "missing"))
        assert scanner.scan_directory(db_session)["gc_skipped"] == "storage_unavailable"
    finally:
        shutil.rmtree(empty_mountpoint, ignore_errors=True)
    assert len(indexed(db_session)) == 3


def test_gc_keeps_rows_of_an_offline_top_level_folder(storage, db_session):
    put(storage, "Imports/other.txt", b"storage root is not empty")
    _orphans(db_session, storage, 3, top="Vault")  # Vault/ itself doesn't exist (separate disk offline)
    stats = scanner.scan_directory(db_session)
    assert stats["stale_deleted"] == 0
    assert len(indexed(db_session)) == 3


def test_gc_refuses_mass_deletion(storage, db_session):
    for i in range(10):
        put(storage, f"Vault/Harsh/Iphone/ok_{i}.jpg")
    scanner.scan_directory(db_session)
    _orphans(db_session, storage, 15)
    stats = scanner.scan_directory(db_session)
    assert stats["gc_skipped"] == "too_many_missing" and stats["stale_deleted"] == 0
    assert len(indexed(db_session)) == 25
    stats = scanner.scan_directory(db_session, allow_mass_delete=True)
    assert stats["stale_deleted"] == 15


def test_gc_drops_rows_under_excluded_folders(storage, db_session):
    from models import MediaFile

    mirror = put(storage, "Mirrors/Harsh/Mac/IMG_9.jpg")
    db_session.add(MediaFile(filename="IMG_9.jpg", path=mirror, relative_path="Mirrors/Harsh/Mac/IMG_9.jpg",
                             directory="Mirrors/Harsh/Mac", extension=".jpg", media_type="image"))
    db_session.commit()
    put(storage, "Vault/Harsh/Iphone/IMG_10.jpg")
    stats = scanner.scan_directory(db_session)
    assert stats["stale_deleted"] == 1
    assert set(indexed(db_session)) == {"Vault/Harsh/Iphone/IMG_10.jpg"}
    assert os.path.exists(mirror)  # only the DB row goes, never the file


def test_index_single_file_sets_source_and_is_idempotent(storage, db_session):
    path = put(storage, "Vault/Harsh/Iphone/IMG_11.jpg")
    first = scanner.index_single_file(path, db_session)
    assert first is not None and first.source == "iphone"
    assert scanner.index_single_file(path, db_session).id == first.id
    assert scanner.index_single_file(os.path.join(storage, "missing.jpg"), db_session) is None


def test_canonical_v2_objects_are_indexed_under_their_display_name(storage, db_session, default_exclusions):
    put(storage, "Vault/2026/09/0123456789abcdef_IMG_1234.PNG")
    scanner.scan_directory(db_session)
    row = indexed(db_session)["Vault/2026/09/0123456789abcdef_IMG_1234.PNG"]
    assert row.filename == "IMG_1234.PNG"
    assert row.is_screenshot          # iPhone PNG pattern, matched on the display name
    assert row.source == "unknown"    # not registered in the v2 tables


def test_platform_mapping_matches_the_ingest_upsert(monkeypatch):
    from routers.ingest_v2 import v1_source_key

    cases = [("iOS", "x"), ("macOS", "x"), ("Windows", "x"), (None, "iphone_harsh"), (None, "mac_harsh"),
             (None, "win_laptop_hp"), ("Linux", "nas_box"), (None, None)]
    for platform, sid in cases:
        assert scanner._platform_source(platform, sid) == v1_source_key(sid, platform)
    # The standalone fallback agrees too
    import builtins
    real_import = builtins.__import__

    def no_routers(name, *args, **kwargs):
        if name.startswith("routers"):
            raise ImportError(name)
        return real_import(name, *args, **kwargs)

    monkeypatch.setattr(builtins, "__import__", no_routers)
    for platform, sid in cases:
        assert scanner._platform_source(platform, sid) == v1_source_key(sid, platform)
