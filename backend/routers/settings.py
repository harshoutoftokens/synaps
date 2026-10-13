"""
Synaps Settings Router
"""
from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from database import get_db
from models import Setting
from config import STORAGE_PATH, THUMBNAIL_DIR, TRASH_DIR
from routers.media import library_counts
from routers.trash import STORAGE_TRASH_DIR
from thumbnails import lower_thread_priority
import os
import time
import shutil
import logging
import threading

logger = logging.getLogger("synaps.settings")

router = APIRouter(prefix="/api/settings", tags=["settings"])

# Settings the web Settings page writes, with their allowed values. Everything else is
# rejected: the path keys below are server configuration and read-only over the API.
WRITABLE_SETTINGS = {
    "theme": {"light", "dark", "system"},
}
SERVER_PATH_SETTINGS = ("storage_path", "thumbnail_dir", "trash_dir")

# Walking the thumbnail cache (100k+ files) on every Sidebar load is far too slow for a
# spinning disk: sizes are computed in the background and reused for 10 minutes.
DIR_SIZE_TTL = 600
_size_cache = {}          # path -> (computed_at monotonic, size)
_size_refreshing = set()
_size_lock = threading.Lock()


@router.get("")
@router.get("/")
def get_settings(db: Session = Depends(get_db)):
    settings = db.query(Setting).all()
    result = {s.key: s.value for s in settings}
    # Defaults
    defaults = {
        "theme": "system",
    }
    for k, v in defaults.items():
        if k not in result:
            result[k] = v
    # Paths always come from the running server's config (a stored row can't override them)
    result.update({
        "storage_path": STORAGE_PATH,
        "thumbnail_dir": THUMBNAIL_DIR,
        "trash_dir": TRASH_DIR,
    })
    return result


@router.put("")
@router.put("/")
def update_settings(data: dict, db: Session = Depends(get_db)):
    unknown = sorted(str(key)[:64] for key in data if key not in WRITABLE_SETTINGS)
    if unknown:
        raise HTTPException(status_code=400, detail=f"Unknown or read-only setting(s): {', '.join(unknown[:10])}")
    for key, value in data.items():
        if not isinstance(value, str) or value not in WRITABLE_SETTINGS[key]:
            allowed = ", ".join(sorted(WRITABLE_SETTINGS[key]))
            raise HTTPException(status_code=400, detail=f"Invalid value for {key} (allowed: {allowed})")

    for key, value in data.items():
        existing = db.query(Setting).filter(Setting.key == key).first()
        if existing:
            existing.value = value
        else:
            db.add(Setting(key=key, value=value))
    db.commit()
    return {"status": "success"}


@router.get("/storage-usage")
def get_storage_usage(db: Session = Depends(get_db)):
    counts = library_counts(db)
    total_indexed = counts["total_size"]
    thumb_size = _cached_dir_size(THUMBNAIL_DIR)
    trash_parts = [_cached_dir_size(d) for d in (TRASH_DIR, STORAGE_TRASH_DIR)]
    trash_size = None if None in trash_parts else sum(trash_parts)
    disk = _disk_usage(STORAGE_PATH)
    return {
        "total_indexed_size": total_indexed,
        "total_indexed_human": _fmt(total_indexed),
        "total_files": counts["total"],
        "images": counts["images"], "videos": counts["videos"], "documents": counts["documents"],
        "thumbnail_cache_size": thumb_size or 0,
        "thumbnail_cache_human": _fmt(thumb_size) if thumb_size is not None else "Calculating…",
        "trash_size": trash_size or 0,
        "trash_size_human": _fmt(trash_size) if trash_size is not None else "Calculating…",
        # Whole-disk numbers for the storage volume (instant: statvfs, no tree walk)
        "disk_total": disk[0],
        "disk_used": disk[1],
        "disk_free": disk[2],
        "disk_total_human": _fmt(disk[0]),
        "disk_used_human": _fmt(disk[1]),
        "disk_free_human": _fmt(disk[2]),
    }


def _disk_usage(path):
    try:
        usage = shutil.disk_usage(path)
        return usage.total, usage.used, usage.free
    except OSError:
        return 0, 0, 0


def _cached_dir_size(path):
    """Last known size of `path` (None until the first background walk finishes).
    A stale or missing value starts a background refresh; the request never waits for it."""
    now = time.monotonic()
    with _size_lock:
        cached = _size_cache.get(path)
        stale = cached is None or now - cached[0] > DIR_SIZE_TTL
        if stale and path not in _size_refreshing:
            _size_refreshing.add(path)
            threading.Thread(target=_refresh_dir_size, args=(path,), name="synaps-dir-size", daemon=True).start()
    return cached[1] if cached else None


def _refresh_dir_size(path):
    lower_thread_priority()  # a cold walk of 100k thumbnails must not slow down requests
    try:
        size = _dir_size(path)
        with _size_lock:
            _size_cache[path] = (time.monotonic(), size)
    except Exception as e:
        logger.warning(f"Could not measure {path}: {e}")
    finally:
        with _size_lock:
            _size_refreshing.discard(path)


def _dir_size(path):
    """Total size of the files under `path` (scandir-based; symlinks are not followed)."""
    total = 0
    stack = [path]
    while stack:
        current = stack.pop()
        try:
            with os.scandir(current) as it:
                for entry in it:
                    try:
                        if entry.is_dir(follow_symlinks=False):
                            stack.append(entry.path)
                        elif entry.is_file(follow_symlinks=False):
                            total += entry.stat(follow_symlinks=False).st_size
                    except OSError:
                        continue
        except OSError:
            continue
    return total


def _fmt(size):
    if not size:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    s = float(size)
    while s >= 1024 and i < len(units) - 1:
        s /= 1024
        i += 1
    return f"{s:.1f} {units[i]}"
