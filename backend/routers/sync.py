"""
Synaps Sync Router — iPhone upload/sync APIs

Uploads (the web app's Sync page) are copied from Starlette's spooled temp file into the
staging area in 1 MB chunks, hashed on the way, deduplicated, then linked into
SYNC_TARGET_DIR/YYYY/MM without ever overwriting an existing file, recorded, and indexed
so they show up in the timeline right away. All of it runs in a worker thread.
"""
from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Form, Query
from sqlalchemy.orm import Session
from typing import Optional, Tuple
import os
import logging
import threading
from datetime import datetime

from database import get_db, SessionLocal
from models import SyncRecord, MediaFile
from models_v2 import PhysicalObject
from config import SYNC_TARGET_DIR, ALL_MEDIA_EXTENSIONS, STORAGE_PATH, SOURCE_MAPPING
from scanner import compute_content_hash
from storage_engine import StagedUpload, sanitize_filename, claim_unique_path, init_storage_directories
from routers.ingest_v2 import ensure_free_space, storage_http_error, SHA_PREFIX_RE

logger = logging.getLogger("synaps.sync")

router = APIRouter(prefix="/api/sync", tags=["sync"])

# Dedup check + placement + record happen atomically per process, so two simultaneous
# uploads of the same photo can't both pass the duplicate check.
_SYNC_LOCK = threading.Lock()


def _source_for_path(filepath: str) -> str:
    """Same source derivation as scanner.scan_directory (Vault/<Owner>/<Device>/...)."""
    parts = os.path.relpath(filepath, STORAGE_PATH).split(os.sep)
    if len(parts) >= 3 and parts[0] == "Vault":
        return SOURCE_MAPPING.get(parts[2], parts[2].lower())
    return "unknown"


def _find_duplicate(db: Session, staged: StagedUpload) -> Optional[Tuple[str, str]]:
    """Return (message, filename) if this content is already on the NAS."""
    existing = db.query(SyncRecord).filter(SyncRecord.file_hash == staged.md5).first()
    if not existing:
        existing = db.query(SyncRecord).filter(SyncRecord.content_hash == staged.sha256).first()
    if existing:
        return f"File already synced as {existing.filename}", existing.filename

    existing_media = db.query(MediaFile).filter(MediaFile.content_hash == staged.sha256).first()
    if not existing_media:
        # media_files.file_hash is the MD5 of the first 64 KB only: a match (with the same
        # size) is just a candidate, confirmed with the full SHA-256 - cached for next time.
        candidates = (
            db.query(MediaFile)
            .filter(
                MediaFile.file_hash == staged.head_md5,
                MediaFile.file_size == staged.size,
                MediaFile.content_hash.is_(None),
            )
            .limit(20)
            .all()
        )
        for candidate in candidates:
            if not os.path.exists(candidate.path):
                continue
            candidate.content_hash = compute_content_hash(candidate.path) or None
            if candidate.content_hash == staged.sha256:
                existing_media = candidate
                break
    if existing_media:
        return f"File already exists as {existing_media.filename}", existing_media.filename

    phys = db.query(PhysicalObject).filter(PhysicalObject.sha256 == staged.sha256).first()
    if phys:
        name = os.path.basename(phys.physical_path)
        name = SHA_PREFIX_RE.sub("", name) or name
        return f"File already exists as {name}", name
    return None


def _index_for_timeline(dest_path: str, sha256: str) -> Optional[str]:
    """Create the media_files row now (the startup scan is disabled), like a rescan would."""
    db = SessionLocal()
    try:
        from scanner import index_single_file
        media = index_single_file(dest_path, db)
        if media is None:
            return None
        changed = False
        if not media.source:
            media.source = _source_for_path(dest_path)
            changed = True
        if not media.content_hash:
            media.content_hash = sha256
            changed = True
        if changed:
            db.commit()
        return media.id
    except Exception as e:
        logger.warning(f"Could not index uploaded file {dest_path}: {e}")
        return None
    finally:
        db.close()


def _store_upload(upload: UploadFile, filename: str, device: str) -> dict:
    """Stream one uploaded file into the library. Returns the single-upload response."""
    init_storage_directories()
    size = getattr(upload, "size", None)
    if size:
        ensure_free_space(size)

    staged = StagedUpload(filename, full_md5=True)
    try:
        upload.file.seek(0)
        staged.copy_from(upload.file)
        staged.finish()

        with _SYNC_LOCK:
            db = SessionLocal()
            try:
                duplicate = _find_duplicate(db, staged)
                if duplicate:
                    db.commit()  # keep content hashes computed while checking
                    message, existing_name = duplicate
                    return {
                        "status": "duplicate",
                        "message": message,
                        "filename": existing_name,
                    }

                # Organize into year/month folders; a taken name gets a _1, _2... suffix
                now = datetime.now()
                year_month_dir = os.path.join(SYNC_TARGET_DIR, str(now.year), f"{now.month:02d}")
                dest_path = claim_unique_path(staged.path, year_month_dir, filename)

                # Record sync
                db.add(SyncRecord(
                    filename=os.path.basename(dest_path),
                    file_hash=staged.md5,
                    content_hash=staged.sha256,
                    hash_algorithm="sha256",
                    file_size=staged.size,
                    destination_path=dest_path,
                    source_device=device,
                ))
                db.commit()
            finally:
                db.close()
    finally:
        staged.discard()

    media_id = _index_for_timeline(dest_path, staged.sha256)

    # Enqueue silent background thumbnail generation immediately
    try:
        from thumbnails import enqueue_thumbnail
        enqueue_thumbnail(dest_path)
    except Exception:
        pass

    return {
        "status": "success",
        "message": "File uploaded successfully",
        "filename": os.path.basename(dest_path),
        "path": dest_path,
        "size": staged.size,
        "media_id": media_id,
    }


@router.post("/upload")
def upload_file(
    file: UploadFile = File(...),
    device: str = Form("iPhone"),
):
    """
    Upload a file from iPhone. Handles deduplication and
    organizes into year/month folders.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No filename provided")

    # The client picks the name: never let it pick the folder
    filename = sanitize_filename(file.filename)
    ext = os.path.splitext(filename)[1].lower()
    if ext not in ALL_MEDIA_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")

    try:
        return _store_upload(file, filename, device)
    except OSError as e:
        logger.error(f"Upload of {filename} failed: {e}")
        raise storage_http_error(e)


@router.post("/upload-batch")
def upload_batch(
    files: list[UploadFile] = File(...),
    device: str = Form("iPhone"),
):
    """Upload multiple files at once."""
    results = []
    for file in files:
        try:
            filename = sanitize_filename(file.filename or "unnamed")
            ext = os.path.splitext(filename)[1].lower()
            if ext not in ALL_MEDIA_EXTENSIONS:
                results.append({"filename": file.filename, "status": "skipped", "reason": "unsupported"})
                continue

            outcome = _store_upload(file, filename, device)
            if outcome["status"] == "duplicate":
                results.append({"filename": file.filename, "status": "duplicate"})
            else:
                results.append({"filename": file.filename, "status": "success"})
        except HTTPException as e:
            results.append({"filename": file.filename, "status": "error", "reason": str(e.detail)})
        except Exception as e:
            results.append({"filename": file.filename, "status": "error", "reason": str(e)})

    return {
        "total": len(results),
        "success": sum(1 for r in results if r["status"] == "success"),
        "duplicates": sum(1 for r in results if r["status"] == "duplicate"),
        "errors": sum(1 for r in results if r["status"] == "error"),
        "results": results,
    }


@router.get("/history")
def get_sync_history(
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=1000),
    db: Session = Depends(get_db),
):
    """Get sync history."""
    total = db.query(SyncRecord).count()
    offset = (page - 1) * per_page
    records = db.query(SyncRecord).order_by(SyncRecord.synced_at.desc()).offset(offset).limit(per_page).all()

    return {
        "total": total,
        "page": page,
        "records": [
            {
                "id": r.id,
                "filename": r.filename,
                "file_size": r.file_size,
                "source_device": r.source_device,
                "synced_at": r.synced_at.isoformat() if r.synced_at else None,
            }
            for r in records
        ],
    }


@router.get("/check-duplicate")
def check_duplicate(file_hash: str, db: Session = Depends(get_db)):
    """Check if a file hash already exists (for client-side dedup)."""
    exists = db.query(SyncRecord).filter(SyncRecord.file_hash == file_hash).first() is not None
    if not exists:
        exists = db.query(MediaFile).filter(MediaFile.file_hash == file_hash).first() is not None
    return {"exists": exists}
