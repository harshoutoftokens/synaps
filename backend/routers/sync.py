"""
Synaps Sync Router — iPhone upload/sync APIs
"""
from fastapi import APIRouter, UploadFile, File, Depends, HTTPException, Form
from sqlalchemy.orm import Session
from typing import Optional
import os
import hashlib
import shutil
from datetime import datetime

from database import get_db
from models import SyncRecord, MediaFile
from config import SYNC_TARGET_DIR, ALL_MEDIA_EXTENSIONS
from scanner import classify_media, get_best_date, compute_file_hash

router = APIRouter(prefix="/api/sync", tags=["sync"])


@router.post("/upload")
async def upload_file(
    file: UploadFile = File(...),
    device: str = Form("iPhone"),
    db: Session = Depends(get_db),
):
    """
    Upload a file from iPhone. Handles deduplication and
    organizes into year/month folders.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="No filename provided")

    ext = os.path.splitext(file.filename)[1].lower()
    if ext not in ALL_MEDIA_EXTENSIONS:
        raise HTTPException(status_code=400, detail=f"Unsupported file type: {ext}")

    # Read file content
    content = await file.read()
    file_hash = hashlib.md5(content).hexdigest()

    # Check for duplicates
    existing = db.query(SyncRecord).filter(SyncRecord.file_hash == file_hash).first()
    if existing:
        return {
            "status": "duplicate",
            "message": f"File already synced as {existing.filename}",
            "filename": existing.filename,
        }

    # Also check existing media files
    existing_media = db.query(MediaFile).filter(MediaFile.file_hash == file_hash).first()
    if existing_media:
        return {
            "status": "duplicate",
            "message": f"File already exists as {existing_media.filename}",
            "filename": existing_media.filename,
        }

    # Organize into year/month folders
    now = datetime.now()
    year_month_dir = os.path.join(SYNC_TARGET_DIR, str(now.year), f"{now.month:02d}")
    os.makedirs(year_month_dir, exist_ok=True)

    # Save file
    dest_path = os.path.join(year_month_dir, file.filename)
    
    # Handle name collision
    counter = 1
    base_name, ext_part = os.path.splitext(file.filename)
    while os.path.exists(dest_path):
        dest_path = os.path.join(year_month_dir, f"{base_name}_{counter}{ext_part}")
        counter += 1

    with open(dest_path, "wb") as f:
        f.write(content)

    # Record sync
    sync_record = SyncRecord(
        filename=os.path.basename(dest_path),
        file_hash=file_hash,
        file_size=len(content),
        destination_path=dest_path,
        source_device=device,
    )
    db.add(sync_record)
    db.commit()

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
        "size": len(content),
    }


@router.post("/upload-batch")
async def upload_batch(
    files: list[UploadFile] = File(...),
    device: str = Form("iPhone"),
    db: Session = Depends(get_db),
):
    """Upload multiple files at once."""
    results = []
    for file in files:
        try:
            # Reset file position
            content = await file.read()
            file_hash = hashlib.md5(content).hexdigest()

            ext = os.path.splitext(file.filename or "")[1].lower()
            if ext not in ALL_MEDIA_EXTENSIONS:
                results.append({"filename": file.filename, "status": "skipped", "reason": "unsupported"})
                continue

            # Check duplicates
            existing = db.query(SyncRecord).filter(SyncRecord.file_hash == file_hash).first()
            if existing:
                results.append({"filename": file.filename, "status": "duplicate"})
                continue

            now = datetime.now()
            year_month_dir = os.path.join(SYNC_TARGET_DIR, str(now.year), f"{now.month:02d}")
            os.makedirs(year_month_dir, exist_ok=True)

            dest_path = os.path.join(year_month_dir, file.filename or "unnamed")
            counter = 1
            base_name, ext_part = os.path.splitext(file.filename or "unnamed")
            while os.path.exists(dest_path):
                dest_path = os.path.join(year_month_dir, f"{base_name}_{counter}{ext_part}")
                counter += 1

            with open(dest_path, "wb") as f:
                f.write(content)

            sync_record = SyncRecord(
                filename=os.path.basename(dest_path),
                file_hash=file_hash,
                file_size=len(content),
                destination_path=dest_path,
                source_device=device,
            )
            db.add(sync_record)
            results.append({"filename": file.filename, "status": "success"})

            # Enqueue silent background thumbnail generation immediately
            try:
                from thumbnails import enqueue_thumbnail
                enqueue_thumbnail(dest_path)
            except Exception:
                pass
        except Exception as e:
            results.append({"filename": file.filename, "status": "error", "reason": str(e)})

    db.commit()
    return {
        "total": len(results),
        "success": sum(1 for r in results if r["status"] == "success"),
        "duplicates": sum(1 for r in results if r["status"] == "duplicate"),
        "errors": sum(1 for r in results if r["status"] == "error"),
        "results": results,
    }


@router.get("/history")
def get_sync_history(
    page: int = 1,
    per_page: int = 50,
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
