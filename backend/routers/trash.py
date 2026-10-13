"""
Synaps Trash Router — Trash management APIs

Safety rules:
- Only media inside the storage root can be trashed or restored, and only files inside a
  trash directory are ever deleted from disk.
- Files that belong to the v2 vault are refused with 409: canonical objects registered in
  physical_objects, anything hardlinked (deleting one link frees no space and orphans the
  other), symlinks and anything under Mirrors/. Removing one of those would leave v2 records
  pointing at nothing while the bytes stay on disk.
- Restore never overwrites: if the original path is taken again, the file comes back as
  "name (restored).ext", "name (restored 2).ext", ...
- When TRASH_DIR is on another filesystem than the file, the file goes to a hidden
  STORAGE_PATH/.synaps_trash instead, so trashing is a rename, not a multi-GB copy.
- Expired items are purged by cleanup_expired(), which main.py also runs on a schedule.
"""
from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session
from datetime import datetime, timedelta
import os
import uuid
import shutil
import logging

from database import get_db
from models import MediaFile, TrashItem
from config import STORAGE_PATH, TRASH_DIR, TRASH_RETENTION_DAYS
from thumbnails import get_thumbnail_path, find_fresh_thumbnail
from fastapi.responses import Response
from routers.media import SVG_PLACEHOLDER, cached_file_response, THUMBNAIL_CACHE_CONTROL
from routers.finder import is_within
from scanner import vault_protection_reason

logger = logging.getLogger("synaps.trash")

router = APIRouter(prefix="/api/trash", tags=["trash"])

# Same-disk trash for when TRASH_DIR (backend/trash) is on another filesystem.
STORAGE_TRASH_DIR = os.path.join(STORAGE_PATH, ".synaps_trash")


def trash_dirs() -> list:
    return [TRASH_DIR, STORAGE_TRASH_DIR]


def _inside_storage(path: str) -> bool:
    # realpath of the parent: a final symlink component is judged separately (refused)
    parent = os.path.realpath(os.path.dirname(path))
    return is_within(parent, os.path.realpath(STORAGE_PATH))


def _inside_trash(path: str) -> bool:
    real = os.path.realpath(path)
    return any(is_within(real, os.path.realpath(d)) for d in trash_dirs())


def _trash_dir_for(path: str) -> str:
    """TRASH_DIR, or the storage-side trash if TRASH_DIR lives on another filesystem."""
    os.makedirs(TRASH_DIR, exist_ok=True)
    try:
        if os.stat(TRASH_DIR).st_dev == os.stat(os.path.dirname(path)).st_dev:
            return TRASH_DIR
    except OSError:
        return TRASH_DIR
    return STORAGE_TRASH_DIR


def _safe_trash_name(item: MediaFile) -> str:
    name = os.path.basename(item.filename or "") or os.path.basename(item.path) or "file"
    # Unique per call: two files with the same name trashed in the same second must not collide
    return f"{datetime.now().strftime('%Y%m%d_%H%M%S')}_{uuid.uuid4().hex[:8]}_{name}"


def _restore_candidates(original_path: str):
    yield original_path
    base, ext = os.path.splitext(original_path)
    yield f"{base} (restored){ext}"
    for n in range(2, 1000):
        yield f"{base} (restored {n}){ext}"


def _move_no_clobber(src: str, dst: str) -> None:
    """Move src to dst, raising FileExistsError instead of overwriting (os.rename would)."""
    try:
        os.link(src, dst)  # atomic: fails with EEXIST rather than replacing dst
    except FileExistsError:
        raise
    except OSError:
        # Other filesystem (or no hardlink support): checked copy-move
        if os.path.lexists(dst):
            raise FileExistsError(dst)
        shutil.move(src, dst)
        return
    os.unlink(src)


def _remove_trash_file(item: TrashItem) -> None:
    """Delete a trash item's file — only ever from inside a trash directory."""
    if not os.path.lexists(item.trash_path):
        return
    if not _inside_trash(item.trash_path):
        raise PermissionError(f"refusing to delete {item.trash_path}: not inside a trash directory")
    os.remove(item.trash_path)


def _remove_thumbnail(original_path: str) -> None:
    try:
        os.remove(get_thumbnail_path(original_path))
    except OSError:
        pass


@router.post("/delete/{media_id}")
def move_to_trash(media_id: str, db: Session = Depends(get_db)):
    """Move a media file to trash."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")
    try:
        st = os.lstat(item.path)
    except OSError:
        raise HTTPException(status_code=404, detail="File not found on disk")
    if not _inside_storage(item.path):
        raise HTTPException(status_code=409, detail=f"{item.filename} is outside the storage root")
    reason = vault_protection_reason(item.path, db, st)
    if reason:
        raise HTTPException(
            status_code=409,
            detail=f"{item.filename} {reason}; it can't be moved to trash from here",
        )

    trash_dir = _trash_dir_for(item.path)
    os.makedirs(trash_dir, exist_ok=True)
    trash_path = os.path.join(trash_dir, _safe_trash_name(item))

    try:
        shutil.move(item.path, trash_path)
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to move file: {e}")

    trash_item = TrashItem(
        original_path=item.path,
        trash_path=trash_path,
        filename=item.filename,
        file_size=item.file_size,
        media_type=item.media_type,
        auto_delete_at=datetime.now() + timedelta(days=TRASH_RETENTION_DAYS),
    )
    db.add(trash_item)
    db.delete(item)
    try:
        db.commit()
    except Exception as e:
        db.rollback()
        # Keep disk and DB consistent: put the file back where it was
        try:
            shutil.move(trash_path, trash_item.original_path)
        except Exception as move_err:
            logger.critical(f"Trash commit failed and file stays at {trash_path}: {move_err}")
        raise HTTPException(status_code=500, detail=f"Failed to record trash item: {e}")

    return {"status": "success", "message": f"{trash_item.filename} moved to trash"}


@router.get("")
@router.get("/")
def list_trash(db: Session = Depends(get_db)):
    """List all items in trash."""
    items = db.query(TrashItem).order_by(TrashItem.deleted_at.desc()).all()
    now = datetime.now()
    return {
        "total": len(items),
        "items": [
            {
                "id": i.id, "filename": i.filename, "file_size": i.file_size,
                "media_type": i.media_type,
                "deleted_at": i.deleted_at.isoformat() if i.deleted_at else None,
                "auto_delete_at": i.auto_delete_at.isoformat() if i.auto_delete_at else None,
                "days_remaining": max(0, (i.auto_delete_at - now).days) if i.auto_delete_at else 0,
                "thumbnail_url": f"/api/trash/thumbnail/{i.id}"
            }
            for i in items
        ],
    }


@router.get("/thumbnail/{trash_id}")
@router.head("/thumbnail/{trash_id}", include_in_schema=False)
def get_trash_thumbnail(trash_id: str, request: Request, db: Session = Depends(get_db)):
    """Get the cached thumbnail for a trash item."""
    item = db.query(TrashItem).filter(TrashItem.id == trash_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Trash item not found")

    # The thumbnail path is based on the original file path
    thumb_path = get_thumbnail_path(item.original_path)
    thumb_stat = find_fresh_thumbnail(thumb_path)
    if thumb_stat is not None:
        return cached_file_response(request, thumb_path, "image/webp", THUMBNAIL_CACHE_CONTROL, thumb_stat)

    # If thumbnail doesn't exist, we just return the placeholder
    return Response(content=SVG_PLACEHOLDER, media_type="image/svg+xml", headers={"Cache-Control": "no-store"})


@router.post("/restore/{trash_id}")
def restore_from_trash(trash_id: str, db: Session = Depends(get_db)):
    """Restore a file from trash and re-index it for the timeline.
    Never overwrites a file that has appeared at the original path in the meantime."""
    from scanner import index_single_file

    item = db.query(TrashItem).filter(TrashItem.id == trash_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Trash item not found")

    if not os.path.exists(item.trash_path):
        raise HTTPException(status_code=404, detail="Trash file not found on disk")
    if not _inside_trash(item.trash_path):
        raise HTTPException(status_code=409, detail="Trash file is not inside a trash directory")
    if not _inside_storage(item.original_path):
        raise HTTPException(status_code=409, detail="Original location is outside the storage root")

    os.makedirs(os.path.dirname(item.original_path), exist_ok=True)
    restored_path = None
    try:
        for candidate in _restore_candidates(item.original_path):
            try:
                _move_no_clobber(item.trash_path, candidate)
            except FileExistsError:
                continue
            restored_path = candidate
            break
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Failed to restore: {e}")
    if restored_path is None:
        raise HTTPException(status_code=409, detail="No free file name to restore to")

    # Re-index the file so it appears in the timeline immediately
    restored_media = index_single_file(restored_path, db)

    db.delete(item)
    db.commit()
    return {
        "status": "success",
        "message": f"{item.filename} restored",
        "media_id": restored_media.id if restored_media else None,
        "restored_filename": os.path.basename(restored_path),
    }


@router.delete("/permanent/{trash_id}")
def permanent_delete(trash_id: str, db: Session = Depends(get_db)):
    """Permanently delete a file from trash."""
    item = db.query(TrashItem).filter(TrashItem.id == trash_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Trash item not found")

    try:
        _remove_trash_file(item)
    except PermissionError as e:
        logger.error(str(e))
        raise HTTPException(status_code=409, detail="Trash file is not inside a trash directory")
    except OSError as e:
        raise HTTPException(status_code=500, detail=f"Failed to delete: {e}")
    _remove_thumbnail(item.original_path)

    db.delete(item)
    db.commit()
    return {"status": "success", "message": f"{item.filename} permanently deleted"}


@router.post("/cleanup")
def cleanup_expired(db: Session = Depends(get_db)):
    """Auto-delete expired trash items (older than 30 days).
    Stable entry point: main.py's lifespan calls cleanup_expired(db) on a schedule."""
    expired = db.query(TrashItem).filter(TrashItem.auto_delete_at <= datetime.now()).all()
    count = 0
    errors = 0
    for item in expired:
        try:
            _remove_trash_file(item)
        except OSError as e:  # includes PermissionError for paths outside the trash dirs
            errors += 1
            logger.error(f"Trash purge skipped {item.trash_path}: {e}")
            continue
        _remove_thumbnail(item.original_path)
        db.delete(item)
        count += 1
    db.commit()
    if count or errors:
        logger.info(f"Trash purge: {count} deleted, {errors} skipped")
    return {"status": "success", "deleted": count, "errors": errors}
