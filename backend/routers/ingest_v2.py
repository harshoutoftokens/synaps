"""
Synaps v2 Ingestion Router.
Provides high-performance, atomic streaming ingestion, client pre-check deduplication,
iPhone album sync, and virtual filesystem hierarchy queries.

Upload data path (PUT /ingest/stream and the legacy multipart POST /ingest/upload share it):
  request body -> STORAGE_PATH/.synaps_tmp/<uuid>.upload<ext> (SHA-256 hashed while written, fsynced)
  -> verify SHA-256 -> date extraction (EXIF / ffprobe) for content the NAS doesn't have yet
  -> under _INGEST_LOCK: rename into Vault/YYYY/MM/<sha16>_<name>, upsert the v2 rows,
     give new objects a v1 media_files row (web timeline), commit, hardlink mirror.
All blocking work runs in worker threads; the event loop only moves bytes.
"""
import os
import re
import errno
import shutil
import asyncio
import logging
import mimetypes
import threading
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Dict, Iterable, List, Optional, Tuple

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form, Query, Request
from fastapi.concurrency import run_in_threadpool
from pydantic import BaseModel
from sqlalchemy.orm import Session, selectinload
from sqlalchemy import case, func, text
from sqlalchemy.exc import IntegrityError
from starlette.requests import ClientDisconnect

from config import ALL_MEDIA_EXTENSIONS, SOURCE_MAPPING, MIN_FREE_BYTES
from database import get_db, SessionLocal
from models import MediaFile
from models_v2 import (
    Source, PhysicalObject, FilesystemNode, LogicalItem,
    Album, AlbumItem, MediaMetadata
)
from storage_engine import (
    StagedUpload, place_in_vault, get_canonical_relative_path, create_hardlink_mirror,
    get_staging_root, get_storage_path, init_storage_directories
)
from node_manager import get_or_create_node_path
from scanner import (
    classify_media, compute_file_hash,
    extract_exif_date, extract_video_date, extract_date_from_filename,
)

logger = logging.getLogger("synaps.ingest_v2")

router = APIRouter(prefix="/api/v2", tags=["ingest_v2"])

CHUNK_SIZE = 256 * 1024  # 256 KB chunks to protect NAS RAM
STREAM_BATCH_BYTES = 1024 * 1024  # hand ~1 MB at a time to the writer thread
SQL_IN_CHUNK = 500  # stay far below SQLite's bound-parameter limit

# Serializes the DB/vault part of every ingest in this process (uploads, pre-check, albums).
# Without it, concurrent uploads of the same content or path race between "SELECT ... none
# found" and INSERT: unique-index violations (500s), duplicate logical items, duplicate
# root folders (NULL parent_id is never "equal" in a unique index). The slow parts -
# receiving, hashing, EXIF/ffprobe - happen outside of it. Across processes (more than one
# uvicorn worker) the unique indexes plus the IntegrityError retry below still apply.
_INGEST_LOCK = threading.Lock()
_COMMIT_ATTEMPTS = 3

_SHA256_RE = re.compile(r"[0-9a-f]{64}")
SHA_PREFIX_RE = re.compile(r"^[0-9a-f]{16}_")
# Types the thumbnail worker can render (same set as /api/finder/thumbnail); a Mac folder sync
# also uploads archives, disk images, documents... which would only occupy the single worker.
_THUMBNAIL_EXTENSIONS = ALL_MEDIA_EXTENSIONS | {".heif", ".webp", ".m4v", ".pdf"}
_MIME_FALLBACK = {
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp",
    ".heic": "image/heic", ".heif": "image/heif", ".gif": "image/gif",
    ".mp4": "video/mp4", ".mov": "video/quicktime", ".m4v": "video/x-m4v",
}


# ── Pydantic Request Models ───────────────────────────────────────────────

class SourceRegistration(BaseModel):
    id: str
    friendly_name: str
    platform: str  # "macOS", "Windows", "iOS"
    volume_identifier: Optional[str] = None


class CheckFileItem(BaseModel):
    original_path: str
    original_filename: str
    file_size: int
    source_location: str
    source_modified_at: Optional[str] = None
    client_sha256: str
    is_favorite: Optional[bool] = False


class CheckBatchRequest(BaseModel):
    source: SourceRegistration
    files: List[CheckFileItem]


class AlbumSyncRequest(BaseModel):
    source_id: str
    album_name: str
    original_paths: List[str]


@dataclass
class IngestParams:
    """Everything an upload carries besides the bytes (form fields or query params)."""
    source_id: str
    original_path: str
    original_filename: str
    source_location: str
    source_created_at: Optional[str] = None
    source_modified_at: Optional[str] = None
    is_favorite: bool = False
    content_type: Optional[str] = None


# ── Helpers ───────────────────────────────────────────────────────────────

def _chunks(values: List, size: int = SQL_IN_CHUNK) -> Iterable[List]:
    for i in range(0, len(values), size):
        yield values[i:i + size]


def _normalize_sha(value: Optional[str]) -> str:
    return (value or "").strip().lower()


def _require_sha(value: Optional[str]) -> str:
    sha = _normalize_sha(value)
    if not _SHA256_RE.fullmatch(sha):
        raise HTTPException(status_code=400, detail="client_sha256 must be 64 hex characters")
    return sha


def _parse_iso(value: Optional[str]) -> Optional[datetime]:
    """ISO-8601 from a client, or None. Python 3.10's fromisoformat() rejects the trailing "Z"
    that Swift's ISO8601DateFormatter emits, so map it to +00:00 first."""
    if not isinstance(value, str) or not value.strip():
        return None
    s = value.strip()
    if s[-1] in "Zz":
        s = s[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(s)
    except ValueError:
        return None


def _naive_utc(dt: Optional[datetime]) -> Optional[datetime]:
    """Provenance timestamps are stored naive; an offset-aware value is stored as UTC wall
    clock (what fromisoformat() + SQLAlchemy already did for "...Z" on Python 3.11+)."""
    if dt is not None and dt.tzinfo is not None:
        return dt.astimezone(timezone.utc).replace(tzinfo=None)
    return dt


def _naive_local(dt: Optional[datetime]) -> Optional[datetime]:
    """Capture dates are local wall clock (like EXIF)."""
    if dt is not None and dt.tzinfo is not None:
        return dt.astimezone().replace(tzinfo=None)
    return dt


def _guess_mime(filename: str, content_type: Optional[str] = None) -> str:
    """The clients send every file part as application/octet-stream; prefer a real type."""
    if content_type:
        base = content_type.split(";")[0].strip().lower()
        if base and base != "application/octet-stream":
            return content_type
    guessed, _ = mimetypes.guess_type((filename or "").lower())
    if guessed:
        return guessed
    return _MIME_FALLBACK.get(os.path.splitext(filename or "")[1].lower(), "application/octet-stream")


def _resolve_capture_date(path: str, filename: str, source_created: Optional[datetime] = None,
                          source_modified: Optional[datetime] = None) -> datetime:
    """
    Same priority as scanner.get_best_date (EXIF > video metadata > filename), but before
    falling back to filesystem times - which for a staging file only say "uploaded now" -
    use the creation/modification time reported by the source device.
    """
    for extract in (lambda: extract_exif_date(path),
                    lambda: extract_video_date(path),
                    lambda: extract_date_from_filename(filename)):
        try:
            found = extract()
        except Exception:
            found = None
        if found:
            return found
    now = datetime.now()
    for candidate in (_naive_local(source_created), _naive_local(source_modified)):
        if candidate and datetime(1971, 1, 1) < candidate <= now:
            return candidate
    # scanner.get_best_date would now fall back to the staging file's own times, i.e. now
    return now


def v1_source_key(source_id: Optional[str], platform: Optional[str]) -> str:
    """Map a v2 device source to the v1 `media_files.source` values the web filters on
    (SOURCE_MAPPING: iphone / mac / windows). The platform decides; the id is only a
    hint for sources with an unknown platform."""
    iphone = SOURCE_MAPPING.get("Iphone", "iphone")
    mac = SOURCE_MAPPING.get("Mac", "mac")
    windows = SOURCE_MAPPING.get("Windows_laptop-HP", "windows")
    p = (platform or "").lower()
    s = (source_id or "").lower()
    if p in ("ios", "iphone", "ipados"):
        return iphone
    if p in ("macos", "darwin", "mac", "osx"):
        return mac
    if p == "windows":
        return windows
    if "iphone" in s or "ios" in s:
        return iphone
    if "mac" in s:
        return mac
    if "win" in s or "laptop" in s or "pc" in s:
        return windows
    return s or "unknown"


def upsert_v1_media_file(
    db: Session,
    phys: PhysicalObject,
    meta: Optional[MediaMetadata] = None,
    source: Optional[Source] = None,
    file_hash: Optional[str] = None,
    date_taken: Optional[datetime] = None,
) -> Optional[MediaFile]:
    """
    Give a v2 canonical Vault file a v1 `media_files` row, so the web timeline, thumbnail and
    file endpoints (which only read media_files) show uploads from the Mac/iPhone apps.
    Built like scanner.scan_directory builds rows and keyed by the same unique `path`, so a
    later manual scan skips the file instead of indexing it twice. Only for canonical paths -
    never for Mirrors/ (hardlinks of the same file). Returns the existing or new row, or
    None for non-media files (the timeline only indexes photos and videos).
    """
    rel_path = phys.physical_path
    full_path = os.path.join(get_storage_path(), rel_path)
    ext = os.path.splitext(rel_path)[1].lower()
    if ext not in ALL_MEDIA_EXTENSIONS:
        return None

    existing = db.query(MediaFile).filter(MediaFile.path == full_path).first()
    if existing:
        return existing

    try:
        file_stat = os.stat(full_path)
    except OSError as e:
        logger.warning(f"Canonical file missing, no timeline entry: {full_path}: {e}")
        return None

    stored_name = os.path.basename(rel_path)
    display_name = SHA_PREFIX_RE.sub("", stored_name) or stored_name
    classification = classify_media(ext, display_name)

    media_file = MediaFile(
        filename=display_name,
        path=full_path,
        relative_path=rel_path,
        directory=os.path.dirname(rel_path),
        source=v1_source_key(source.id, source.platform) if source else "unknown",
        extension=ext,
        mime_type=_guess_mime(display_name, phys.mime_type),
        file_size=phys.file_size or file_stat.st_size,
        media_type=(meta.media_type if meta and meta.media_type else classification["media_type"]),
        is_screenshot=bool(meta.is_screenshot) if meta else classification["is_screenshot"],
        is_screen_recording=bool(meta.is_screen_recording) if meta else classification["is_screen_recording"],
        is_raw=classification["is_raw"],
        is_favorite=bool(meta.is_favorite) if meta else False,
        date_taken=date_taken or (meta.capture_date if meta else None) or datetime.fromtimestamp(file_stat.st_mtime),
        date_created=datetime.fromtimestamp(getattr(file_stat, "st_birthtime", file_stat.st_ctime)),
        date_modified=datetime.fromtimestamp(file_stat.st_mtime),
        file_hash=file_hash or compute_file_hash(full_path),
        content_hash=phys.sha256,
        hash_algorithm="sha256",
        has_thumbnail=False,
    )
    db.add(media_file)
    return media_file


def _get_or_register_source(db: Session, source_id: str) -> Source:
    """Upload path: the source normally registered itself via /ingest/check already."""
    source = db.get(Source, source_id)
    if not source:
        platform = "macOS"
        if "win" in source_id.lower():
            platform = "Windows"
        elif "iphone" in source_id.lower() or "ios" in source_id.lower():
            platform = "iOS"

        source = Source(
            id=source_id,
            friendly_name=source_id,
            platform=platform,
        )
        db.add(source)
        db.flush()
    return source


def _add_ref(deltas: Dict[str, int], phys_id: Optional[str], delta: int):
    if phys_id:
        deltas[phys_id] = deltas.get(phys_id, 0) + delta


def _apply_ref_deltas(db: Session, deltas: Dict[str, int]):
    """Apply reference_count changes (reference_count = number of logical items pointing at
    the object) as SQL-side increments: no lost updates, not even against another process."""
    for phys_id, delta in deltas.items():
        if not delta:
            continue
        new_count = func.coalesce(PhysicalObject.reference_count, 0) + delta
        db.query(PhysicalObject).filter(PhysicalObject.id == phys_id).update(
            {PhysicalObject.reference_count: case((new_count < 0, 0), else_=new_count)},
            synchronize_session=False,
        )


def _repoint_logical(logical: LogicalItem, phys: PhysicalObject, deltas: Dict[str, int]) -> bool:
    """Point an existing logical item at (possibly new) content, moving one reference."""
    if logical.physical_object_id == phys.id:
        return False
    _add_ref(deltas, logical.physical_object_id, -1)
    logical.physical_object_id = phys.id
    _add_ref(deltas, phys.id, +1)
    return True


def _mark_favorite(db: Session, phys: PhysicalObject):
    """A source reports the file as a favorite: set it on the v2 metadata, and on the v1 row
    when the v2 flag flips (so an un-favorite done in the web UI isn't undone every sync)."""
    meta = phys.metadata_record
    if meta is None or meta.is_favorite:
        return
    meta.is_favorite = True
    full_path = os.path.join(get_storage_path(), phys.physical_path)
    db.query(MediaFile).filter(MediaFile.path == full_path).update(
        {"is_favorite": True}, synchronize_session=False
    )


# ── Shared ingest pipeline ────────────────────────────────────────────────

def _commit_ingest(db: Session, staged: StagedUpload, params: IngestParams,
                   capture_date: Optional[datetime]) -> Tuple[dict, dict]:
    """DB + Vault part of an upload (caller holds _INGEST_LOCK and commits).
    Returns (response, after_commit) - after_commit says which mirror to create and which
    orphaned files to delete once the transaction is durable."""
    sha = staged.sha256
    src_created = _parse_iso(params.source_created_at)
    src_modified = _parse_iso(params.source_modified_at)
    orphans: List[str] = []
    ref_deltas: Dict[str, int] = {}

    source = _get_or_register_source(db, params.source_id)

    phys = (
        db.query(PhysicalObject)
        .options(selectinload(PhysicalObject.metadata_record))
        .filter(PhysicalObject.sha256 == sha)
        .first()
    )
    meta = None
    created = False

    if phys is None:
        if staged.placed is None:
            if capture_date is None:
                capture_date = _resolve_capture_date(staged.path, params.original_filename, src_created, src_modified)
            canonical_rel = get_canonical_relative_path(capture_date, sha, params.original_filename)
            canonical_full, _, moved = place_in_vault(staged.path, canonical_rel, sha)
            staged.placed = (canonical_rel, canonical_full, moved)
        canonical_rel, canonical_full, _ = staged.placed
        classification = classify_media(os.path.splitext(params.original_filename)[1].lower(), params.original_filename)

        phys = PhysicalObject(
            sha256=sha,
            file_size=os.path.getsize(canonical_full),
            physical_path=canonical_rel,
            mime_type=_guess_mime(params.original_filename, params.content_type),
            reference_count=0,  # +1 below for the logical item that points at it
        )
        db.add(phys)
        db.flush()  # a concurrent insert of the same SHA-256 fails here (IntegrityError -> retry)

        meta = MediaMetadata(
            physical_object_id=phys.id,
            capture_date=capture_date or _naive_local(src_created),
            media_type=classification["media_type"],
            is_screenshot=classification["is_screenshot"],
            is_screen_recording=classification["is_screen_recording"],
            is_favorite=params.is_favorite,
        )
        db.add(meta)
        created = True
    else:
        # Content already on the NAS: the staging file is deleted by the caller. If an earlier
        # attempt of this request moved it into the Vault under another name, that copy is
        # an orphan now.
        if staged.placed is not None:
            placed_rel, placed_full, moved = staged.placed
            if moved and placed_rel != phys.physical_path:
                orphans.append(placed_full)
        if params.is_favorite:
            _mark_favorite(db, phys)

    node = get_or_create_node_path(
        db=db,
        source_id=source.id,
        original_path=params.original_path,
        platform=source.platform,
        physical_object_id=phys.id
    )

    logical = (
        db.query(LogicalItem)
        .filter(LogicalItem.source_id == source.id, LogicalItem.original_path == params.original_path)
        .first()
    )
    if not logical:
        logical = LogicalItem(
            physical_object_id=phys.id,
            source_id=source.id,
            node_id=node.id,
            original_path=params.original_path,
            original_filename=params.original_filename,
            source_location=params.source_location,
            source_created_at=_naive_utc(src_created),
            source_modified_at=_naive_utc(src_modified),
        )
        db.add(logical)
        _add_ref(ref_deltas, phys.id, +1)
    else:
        # Same file again (no-op for the counts) or new content at the same path (re-point)
        _repoint_logical(logical, phys, ref_deltas)
        logical.node_id = node.id
        logical.is_deleted_on_source = False
        if src_modified:
            logical.source_modified_at = _naive_utc(src_modified)
        if src_created and not logical.source_created_at:
            logical.source_created_at = _naive_utc(src_created)

    if created:
        upsert_v1_media_file(db, phys, meta, source, file_hash=staged.head_md5)

    db.flush()  # assigns logical.id; surfaces constraint errors before commit
    _apply_ref_deltas(db, ref_deltas)

    canonical_full = os.path.join(get_storage_path(), phys.physical_path)
    response = {
        "status": "success",
        "physical_object_id": phys.id,
        "logical_item_id": logical.id,
        "canonical_path": phys.physical_path,
        "mirror_path": None,
        "sha256": phys.sha256,
    }
    after_commit = {
        "mirror": (canonical_full, source.friendly_name, params.original_path, source.platform),
        "canonical_full": canonical_full,
        "orphans": orphans,
    }
    return response, after_commit


def ingest_staged_upload(staged: StagedUpload, params: IngestParams) -> dict:
    """
    Shared by both upload endpoints; runs in a worker thread. `staged` must be finished and
    its SHA-256 verified. The staging file is moved into the Vault or left for the caller to
    delete (staged.discard()). Returns the upload response.
    """
    sha = staged.sha256

    # Reading EXIF / running ffprobe is slow: do it before taking the lock, and only for
    # content the NAS doesn't have yet.
    capture_date = None
    with SessionLocal() as db:
        known = db.query(PhysicalObject.id).filter(PhysicalObject.sha256 == sha).first() is not None
    if not known:
        capture_date = _resolve_capture_date(
            staged.path, params.original_filename,
            _parse_iso(params.source_created_at), _parse_iso(params.source_modified_at),
        )

    with _INGEST_LOCK:
        for attempt in range(1, _COMMIT_ATTEMPTS + 1):
            db = SessionLocal()
            try:
                response, after_commit = _commit_ingest(db, staged, params, capture_date)
                db.commit()
                break
            except IntegrityError as e:
                db.rollback()
                if attempt == _COMMIT_ATTEMPTS:
                    raise
                logger.warning(f"Ingest of {params.original_path} raced another writer, retrying: {e.orig}")
            finally:
                db.close()

        # Mirrors are best effort and idempotent; create them once the rows are committed
        response["mirror_path"] = _make_mirror(*after_commit["mirror"])

    for orphan in after_commit["orphans"]:
        try:
            os.remove(orphan)
        except OSError:
            pass

    # Enqueue silent background thumbnail generation immediately
    if os.path.splitext(after_commit["canonical_full"])[1].lower() in _THUMBNAIL_EXTENSIONS:
        try:
            from thumbnails import enqueue_thumbnail
            enqueue_thumbnail(after_commit["canonical_full"])
        except Exception as e:
            logger.debug(f"Failed to enqueue thumbnail on ingest: {e}")

    return response


def _make_mirror(*args) -> Optional[str]:
    """create_hardlink_mirror that never fails the request: the upload is already committed."""
    try:
        return create_hardlink_mirror(*args)
    except Exception as e:
        logger.error(f"Mirror creation failed for {args[2]!r}: {e}")
        return None


def ensure_free_space(incoming_bytes: int):
    free = shutil.disk_usage(get_staging_root()).free
    if free - incoming_bytes < MIN_FREE_BYTES:
        raise HTTPException(
            status_code=507,
            detail=f"Insufficient storage: {incoming_bytes} bytes requested, {free} bytes free",
        )


def storage_http_error(e: OSError) -> HTTPException:
    if e.errno == errno.ENOSPC:
        return HTTPException(status_code=507, detail="Insufficient storage on the NAS")
    return HTTPException(status_code=500, detail=f"Upload stream error: {e}")


def _consume_future_result(future: "asyncio.Future"):
    """Retrieve an abandoned writer future's exception so asyncio doesn't log it."""
    if not future.cancelled():
        future.exception()


# ── 1. Client Pre-Check (Fast Deduplication) ──────────────────────────────

def _upsert_source(db: Session, reg: SourceRegistration) -> Source:
    source = db.get(Source, reg.id)
    if not source:
        source = Source(
            id=reg.id,
            friendly_name=reg.friendly_name,
            platform=reg.platform,
            volume_identifier=reg.volume_identifier,
        )
        db.add(source)
    else:
        source.friendly_name = reg.friendly_name
        source.last_seen_at = datetime.now()
    db.flush()
    return source


def _check_batch(db: Session, req: CheckBatchRequest) -> Tuple[dict, List[tuple]]:
    """Pre-check body: a few IN queries for the whole batch instead of several per file."""
    source = _upsert_source(db, req.source)

    shas = sorted({_normalize_sha(item.client_sha256) for item in req.files})
    phys_by_sha: Dict[str, PhysicalObject] = {}
    for chunk in _chunks(shas):
        for phys in (
            db.query(PhysicalObject)
            .options(selectinload(PhysicalObject.metadata_record))
            .filter(PhysicalObject.sha256.in_(chunk))
        ):
            phys_by_sha[phys.sha256] = phys

    paths = sorted({item.original_path for item in req.files
                    if _normalize_sha(item.client_sha256) in phys_by_sha})
    logical_by_path: Dict[str, LogicalItem] = {}
    for chunk in _chunks(paths):
        for logical in (
            db.query(LogicalItem)
            .filter(LogicalItem.source_id == source.id, LogicalItem.original_path.in_(chunk))
        ):
            logical_by_path.setdefault(logical.original_path, logical)

    node_cache: dict = {}
    ref_deltas: Dict[str, int] = {}
    mirror_jobs: List[tuple] = []
    results = []
    need_upload_count = 0
    dedup_count = 0

    for item in req.files:
        phys_obj = phys_by_sha.get(_normalize_sha(item.client_sha256))

        if phys_obj is None:
            need_upload_count += 1
            results.append({
                "original_path": item.original_path,
                "status": "need_upload",
                "physical_object_id": None,
            })
            continue

        # Physical file is already on the NAS! Link this provenance to it (zero transfer),
        # unless it is already linked.
        logical = logical_by_path.get(item.original_path)
        if logical is None or logical.physical_object_id != phys_obj.id:
            node = get_or_create_node_path(
                db=db,
                source_id=source.id,
                original_path=item.original_path,
                platform=source.platform,
                physical_object_id=phys_obj.id,
                cache=node_cache,
            )
            mod_dt = _naive_utc(_parse_iso(item.source_modified_at))
            if logical is None:
                logical = LogicalItem(
                    physical_object_id=phys_obj.id,
                    source_id=source.id,
                    node_id=node.id,
                    original_path=item.original_path,
                    original_filename=item.original_filename,
                    source_location=item.source_location,
                    source_modified_at=mod_dt,
                )
                db.add(logical)
                logical_by_path[item.original_path] = logical
                _add_ref(ref_deltas, phys_obj.id, +1)
            else:
                # The file at this path changed to content that is already on the NAS
                _repoint_logical(logical, phys_obj, ref_deltas)
                logical.node_id = node.id
                logical.is_deleted_on_source = False
                if mod_dt:
                    logical.source_modified_at = mod_dt

            # If item is marked favorite, update metadata if not already favorite
            if item.is_favorite:
                _mark_favorite(db, phys_obj)

            mirror_jobs.append((
                os.path.join(get_storage_path(), phys_obj.physical_path),
                source.friendly_name, item.original_path, source.platform,
            ))

        dedup_count += 1
        results.append({
            "original_path": item.original_path,
            "status": "dedup_linked",
            "physical_object_id": phys_obj.id,
        })

    db.flush()
    _apply_ref_deltas(db, ref_deltas)

    response = {
        "source_id": source.id,
        "total_checked": len(req.files),
        "need_upload": need_upload_count,
        "dedup_linked": dedup_count,
        "results": results,
    }
    return response, mirror_jobs


@router.post("/ingest/check")
def check_ingest_batch(req: CheckBatchRequest):
    """
    Checks incoming batch against existing physical objects on the NAS.
    If SHA-256 exists, links provenance instantly with zero network transfer.
    """
    init_storage_directories()

    with _INGEST_LOCK:
        for attempt in range(1, _COMMIT_ATTEMPTS + 1):
            db = SessionLocal()
            try:
                response, mirror_jobs = _check_batch(db, req)
                db.commit()
                break
            except IntegrityError as e:
                db.rollback()
                if attempt == _COMMIT_ATTEMPTS:
                    raise
                logger.warning(f"Pre-check raced another writer, retrying: {e.orig}")
            finally:
                db.close()

        # Create hardlink mirrors on NAS disk
        for job in mirror_jobs:
            _make_mirror(*job)

    return response


# ── 2. Upload Receivers ───────────────────────────────────────────────────

@router.post("/ingest/upload")
def upload_file_v2(
    source_id: str = Form(...),
    original_path: str = Form(...),
    original_filename: str = Form(...),
    source_location: str = Form(...),
    client_sha256: str = Form(...),
    source_created_at: Optional[str] = Form(None),
    source_modified_at: Optional[str] = Form(None),
    is_favorite: bool = Form(False),
    file: UploadFile = File(...),
):
    """
    Legacy multipart upload (Mac/iOS apps, synaps_mac.py). Runs in a worker thread.
    Starlette has already spooled the file part to a temp file; it is copied (and hashed)
    into the staging area once, then goes through the shared ingest pipeline.
    Prefer PUT /api/v2/ingest/stream: no multipart parsing and one disk write per byte.
    """
    client_sha = _require_sha(client_sha256)
    params = IngestParams(
        source_id=source_id,
        original_path=original_path,
        original_filename=original_filename,
        source_location=source_location,
        source_created_at=source_created_at,
        source_modified_at=source_modified_at,
        is_favorite=is_favorite,
        content_type=file.content_type,
    )

    try:
        init_storage_directories()
        size = getattr(file, "size", None)
        if size:
            ensure_free_space(size)
        staged = StagedUpload(original_filename)
    except OSError as e:
        raise storage_http_error(e)

    try:
        try:
            file.file.seek(0)
            staged.copy_from(file.file, CHUNK_SIZE)
            computed_sha = staged.finish()
        except OSError as e:
            logger.error(f"Stream upload failed: {e}")
            raise storage_http_error(e)

        # Verify SHA-256 integrity immediately
        if computed_sha != client_sha:
            raise HTTPException(
                status_code=400,
                detail=f"SHA-256 mismatch: client={client_sha}, computed={computed_sha}"
            )
        try:
            return ingest_staged_upload(staged, params)
        except OSError as e:
            logger.error(f"Ingest of {original_path} failed: {e}")
            raise storage_http_error(e)
    finally:
        staged.discard()


@router.put("/ingest/stream")
async def upload_stream_v2(
    request: Request,
    source_id: str = Query(...),
    original_path: str = Query(...),
    original_filename: str = Query(...),
    source_location: str = Query(...),
    client_sha256: str = Query(...),
    source_created_at: Optional[str] = Query(None),
    source_modified_at: Optional[str] = Query(None),
    is_favorite: bool = Query(False),
):
    """
    Raw streaming upload: the request body is the file (application/octet-stream) and the
    metadata travels in the query string. The body goes straight from the socket into a
    staging file next to the Vault (so the final move is a rename), hashed on the fly:
    one disk write per byte, no multipart parsing. Content-Length is required (411).
    Same response and status codes as POST /api/v2/ingest/upload.
    """
    raw_length = request.headers.get("content-length")
    if raw_length is None:
        raise HTTPException(status_code=411, detail="Content-Length required")
    try:
        expected_bytes = int(raw_length)
    except ValueError:
        expected_bytes = -1
    if expected_bytes < 0:
        raise HTTPException(status_code=400, detail="Invalid Content-Length")

    client_sha = _require_sha(client_sha256)
    params = IngestParams(
        source_id=source_id,
        original_path=original_path,
        original_filename=original_filename,
        source_location=source_location,
        source_created_at=source_created_at,
        source_modified_at=source_modified_at,
        is_favorite=is_favorite,
        content_type=request.headers.get("content-type"),
    )

    def _prepare() -> StagedUpload:
        init_storage_directories()
        ensure_free_space(expected_bytes)
        return StagedUpload(original_filename)

    try:
        staged = await run_in_threadpool(_prepare)
    except OSError as e:
        raise storage_http_error(e)

    loop = asyncio.get_running_loop()
    pending = None  # the previous batch, being written + hashed in a worker thread
    try:
        try:
            batch: List[bytes] = []
            batch_bytes = 0
            received = 0
            async for chunk in request.stream():
                if not chunk:
                    continue
                received += len(chunk)
                if received > expected_bytes:
                    raise HTTPException(status_code=400, detail="Request body is longer than Content-Length")
                batch.append(chunk)
                batch_bytes += len(chunk)
                if batch_bytes >= STREAM_BATCH_BYTES:
                    if pending is not None:
                        await pending
                    # Overlaps disk + SHA-256 work with receiving the next batch (2 cores)
                    pending = loop.run_in_executor(None, staged.write_chunks, batch)
                    batch, batch_bytes = [], 0
            if pending is not None:
                await pending
                pending = None
            if batch:
                await run_in_threadpool(staged.write_chunks, batch)
            if received != expected_bytes:
                raise HTTPException(
                    status_code=400,
                    detail=f"Incomplete upload: received {received} of {expected_bytes} bytes",
                )
            computed_sha = await run_in_threadpool(staged.finish)
        except ClientDisconnect:
            logger.info(f"Client disconnected during streamed upload of {original_path}")
            raise HTTPException(status_code=400, detail="Client disconnected before the upload completed")
        except OSError as e:
            logger.error(f"Stream upload failed: {e}")
            raise storage_http_error(e)

        # Verify SHA-256 integrity immediately
        if computed_sha != client_sha:
            raise HTTPException(
                status_code=400,
                detail=f"SHA-256 mismatch: client={client_sha}, computed={computed_sha}"
            )
        try:
            return await run_in_threadpool(ingest_staged_upload, staged, params)
        except OSError as e:
            logger.error(f"Ingest of {original_path} failed: {e}")
            raise storage_http_error(e)
    finally:
        if pending is not None:
            pending.add_done_callback(_consume_future_result)
        try:
            await run_in_threadpool(staged.discard)
        except BaseException:
            staged.discard()  # cancelled (shutdown): clean up synchronously
            raise


# ── 3. iPhone Album Sync ──────────────────────────────────────────────────

@router.post("/ingest/albums")
@router.post("/ingest/sync-albums", include_in_schema=False)  # path used by the Mac app's syncAlbums()
def sync_albums(req: AlbumSyncRequest):
    """
    Synchronizes album memberships (e.g. from iPhone Photos app).
    """
    with _INGEST_LOCK:
        db = SessionLocal()
        try:
            source = db.get(Source, req.source_id)
            if not source:
                raise HTTPException(status_code=404, detail="Source not found")

            album = (
                db.query(Album)
                .filter(Album.source_id == req.source_id, Album.name == req.album_name)
                .first()
            )

            if not album:
                album = Album(name=req.album_name, source_id=req.source_id)
                db.add(album)
                db.flush()

            paths = list(dict.fromkeys(req.original_paths))
            logical_ids: Dict[str, str] = {}
            for chunk in _chunks(paths):
                for logical_id, original_path in (
                    db.query(LogicalItem.id, LogicalItem.original_path)
                    .filter(LogicalItem.source_id == req.source_id, LogicalItem.original_path.in_(chunk))
                ):
                    logical_ids.setdefault(original_path, logical_id)

            linked_ids = {
                logical_id for (logical_id,) in
                db.query(AlbumItem.logical_item_id).filter(AlbumItem.album_id == album.id)
            }

            linked_count = 0
            for path in paths:
                logical_id = logical_ids.get(path)
                if logical_id and logical_id not in linked_ids:
                    db.add(AlbumItem(album_id=album.id, logical_item_id=logical_id))
                    linked_ids.add(logical_id)
                    linked_count += 1

            db.commit()
            return {
                "album_id": album.id,
                "album_name": album.name,
                "newly_linked_items": linked_count,
            }
        finally:
            db.close()


# ── 4. Virtual Filesystem Navigation APIs ─────────────────────────────────

@router.get("/sources")
def list_sources(db: Session = Depends(get_db)):
    """List all registered device sources with item counts."""
    sources = db.query(Source).all()
    counts = dict(
        db.query(LogicalItem.source_id, func.count(LogicalItem.id))
        .group_by(LogicalItem.source_id)
        .all()
    )
    out = []
    for s in sources:
        out.append({
            **s.to_dict(),
            "total_items": counts.get(s.id, 0),
        })
    return {"sources": out}


@router.get("/sources/{source_id}/tree")
def browse_source_tree(
    source_id: str,
    parent_id: Optional[int] = None,
    db: Session = Depends(get_db)
):
    """
    Instantly browse a directory node in a device's virtual filesystem.
    Returns immediate child folders and files with zero disk scans.
    """
    source = db.query(Source).filter(Source.id == source_id).first()
    if not source:
        raise HTTPException(status_code=404, detail="Source not found")

    # Query immediate child nodes, with their files' provenance + metadata in 3 more queries
    nodes = (
        db.query(FilesystemNode)
        .options(
            selectinload(FilesystemNode.logical_item),
            selectinload(FilesystemNode.physical_object).selectinload(PhysicalObject.metadata_record),
        )
        .filter(FilesystemNode.source_id == source_id, FilesystemNode.parent_id == parent_id)
        .order_by(FilesystemNode.is_directory.desc(), FilesystemNode.name.asc())
        .all()
    )

    # Count immediate children of every listed folder in one grouped query
    folder_ids = [node.id for node in nodes if node.is_directory]
    child_counts: Dict[int, int] = {}
    for chunk in _chunks(folder_ids):
        child_counts.update(
            db.query(FilesystemNode.parent_id, func.count(FilesystemNode.id))
            .filter(FilesystemNode.parent_id.in_(chunk))
            .group_by(FilesystemNode.parent_id)
            .all()
        )

    folders = []
    files = []

    for node in nodes:
        if node.is_directory:
            folders.append({
                "id": node.id,
                "name": node.name,
                "type": "folder",
                "children_count": child_counts.get(node.id, 0),
            })
        else:
            logical = node.logical_item
            phys = node.physical_object
            meta = phys.metadata_record if phys else None

            files.append({
                "id": node.id,
                "name": node.name,
                "type": "file",
                "physical_object_id": node.physical_object_id,
                "logical_item_id": logical.id if logical else None,
                "file_size": phys.file_size if phys else 0,
                "media_type": meta.media_type if meta else "document",
                "is_favorite": meta.is_favorite if meta else False,
                "capture_date": meta.capture_date.isoformat() if meta and meta.capture_date else None,
                "sha256": phys.sha256 if phys else None,
                "original_path": logical.original_path if logical else None,
            })

    # Build breadcrumbs (one recursive query up the parent chain)
    breadcrumbs = [{"id": None, "name": source.friendly_name}]
    if parent_id:
        chain = db.execute(
            text(
                "WITH RECURSIVE chain(id, name, parent_id, depth) AS ("
                " SELECT id, name, parent_id, 0 FROM filesystem_nodes WHERE id = :node_id"
                " UNION ALL"
                " SELECT n.id, n.name, n.parent_id, chain.depth + 1"
                " FROM filesystem_nodes n JOIN chain ON n.id = chain.parent_id"
                " WHERE chain.depth < 512"
                ") SELECT id, name FROM chain ORDER BY depth DESC"
            ),
            {"node_id": parent_id},
        ).all()
        breadcrumbs.extend({"id": row[0], "name": row[1]} for row in chain)

    return {
        "source": source.to_dict(),
        "parent_id": parent_id,
        "breadcrumbs": breadcrumbs,
        "folders": folders,
        "files": files,
        "total_folders": len(folders),
        "total_files": len(files),
    }


@router.get("/albums")
def list_albums(db: Session = Depends(get_db)):
    """List all synced albums with item counts and cover photos."""
    albums = db.query(Album).order_by(Album.name.asc()).all()

    counts = dict(
        db.query(AlbumItem.album_id, func.count(AlbumItem.id)).group_by(AlbumItem.album_id).all()
    )
    # Cover = first item (lowest id) of each album
    first_item_ids = [row[0] for row in db.query(func.min(AlbumItem.id)).group_by(AlbumItem.album_id).all()]
    covers: Dict[str, str] = {}
    for chunk in _chunks(first_item_ids):
        covers.update(
            db.query(AlbumItem.album_id, LogicalItem.physical_object_id)
            .join(LogicalItem, LogicalItem.id == AlbumItem.logical_item_id)
            .filter(AlbumItem.id.in_(chunk))
            .all()
        )

    out = []
    for alb in albums:
        out.append({
            "id": alb.id,
            "name": alb.name,
            "source_id": alb.source_id,
            "item_count": counts.get(alb.id, 0),
            "cover_physical_id": covers.get(alb.id),
            "created_at": alb.created_at.isoformat() if alb.created_at else None,
        })
    return {"albums": out}


@router.get("/albums/{album_id}")
def get_album_items(album_id: str, db: Session = Depends(get_db)):
    """Get all items in a specific album."""
    album = (
        db.query(Album)
        .options(
            selectinload(Album.items)
            .selectinload(AlbumItem.logical_item)
            .selectinload(LogicalItem.physical_object)
            .selectinload(PhysicalObject.metadata_record)
        )
        .filter(Album.id == album_id)
        .first()
    )
    if not album:
        raise HTTPException(status_code=404, detail="Album not found")

    items = []
    for link in album.items:
        logical = link.logical_item
        if logical and logical.physical_object:
            phys = logical.physical_object
            meta = phys.metadata_record
            items.append({
                "logical_id": logical.id,
                "physical_object_id": phys.id,
                "filename": logical.original_filename,
                "original_path": logical.original_path,
                "file_size": phys.file_size,
                "media_type": meta.media_type if meta else "image",
                "is_favorite": meta.is_favorite if meta else False,
                "capture_date": meta.capture_date.isoformat() if meta and meta.capture_date else None,
            })

    return {
        "album": album.to_dict(),
        "items": items,
        "total_items": len(items),
    }
