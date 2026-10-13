"""
Synaps Finder Router — Directory browsing APIs
Optimized for low-power NAS with paginated responses.

Every client-supplied path goes through resolve_storage_path(): it is interpreted relative to
the storage root, '..' components and NUL bytes are rejected (400), hidden entries ('.synaps_tmp',
'.synaps_trash', ...) are not reachable (404), and the realpath must stay inside the storage root
(403), so symlinks cannot be used to escape it.
"""
from fastapi import APIRouter, Depends, Query, HTTPException, Request
from fastapi.responses import Response
from sqlalchemy.orm import Session
from sqlalchemy import text
from collections import OrderedDict
from typing import Optional
import os
import stat
import time
import mimetypes
import logging
import threading
from datetime import datetime

from config import STORAGE_PATH, ALL_EXTENSIONS, IMAGE_EXTENSIONS, VIDEO_EXTENSIONS
from database import get_db
from models import MediaFile
from thumbnails import (
    get_thumbnail_path, find_fresh_thumbnail, schedule_thumbnail, is_thumbnail_pending,
    thumbnail_failed, link_thumbnail,
)
from routers.media import cached_file_response, THUMBNAIL_CACHE_CONTROL, FILE_CACHE_CONTROL

logger = logging.getLogger("synaps.finder")

router = APIRouter(prefix="/api/finder", tags=["finder"])

THUMBNAIL_EXTENSIONS = ALL_EXTENSIONS | {".heic", ".heif", ".mov", ".mp4", ".m4v", ".jpg", ".jpeg", ".png", ".webp", ".pdf"}
DOCUMENT_TYPES = {".pdf", ".doc", ".docx", ".txt", ".md"}

_LISTING_TTL = 60          # seconds a sorted directory listing is reused (paging a big folder)
_LISTING_CACHE_MAX = 4     # directories kept (a 50k-entry listing is a few MB)
_COUNT_TTL = 600           # seconds a folder's children_count is reused (keyed by its mtime too)
_COUNT_CACHE_MAX = 4096
_TREE_TTL = 30
_TREE_MAX_NODES = 5000
_ALIAS_CACHE_MAX = 5000
_IN_QUERY_CHUNK = 500      # stays under SQLite's 999-variable limit on older builds

_cache_lock = threading.Lock()
_listing_cache = OrderedDict()  # real dir -> ((ino, mtime_ns), expires, folders, files)
_count_cache = OrderedDict()    # real dir -> ((ino, mtime_ns), expires, count)
_tree_cache = {}                # depth -> (expires, tree)
_alias_cache = OrderedDict()    # mirror full path -> canonical full path


# ── Path safety ───────────────────────────────────────────────────────────

def is_within(path: str, root: str) -> bool:
    """True if `path` is `root` or inside it (both should be realpaths)."""
    try:
        return os.path.commonpath([path, root]) == root
    except ValueError:
        return False


def storage_root_real() -> str:
    return os.path.realpath(STORAGE_PATH)


def clean_relative_path(path: str) -> str:
    """Normalize a client path relative to the storage root.
    A leading '/' means the storage root (iOS sends "/" for it) — never a host path."""
    if "\x00" in path:
        raise HTTPException(status_code=400, detail="Invalid path")
    parts = []
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise HTTPException(status_code=400, detail="Invalid path")
        parts.append(part)
    return "/".join(parts)


def resolve_storage_path(path: str) -> tuple:
    """Map a client-supplied path onto the storage root.
    Returns (clean_rel, full_path, real_path): full_path is the joined path (the key used for
    thumbnails and media_files.path), real_path the symlink-free path to do I/O on."""
    rel = clean_relative_path(path)
    if any(part.startswith(".") for part in rel.split("/") if part):
        raise HTTPException(status_code=404, detail="Not found")
    full = os.path.join(STORAGE_PATH, rel) if rel else STORAGE_PATH
    real = os.path.realpath(full)
    if not is_within(real, storage_root_real()):
        raise HTTPException(status_code=403, detail="Path is outside the storage root")
    return rel, full, real


def _display(name: str) -> str:
    """JSON-safe form of a filesystem name (undecodable bytes become U+FFFD instead of a 500)."""
    try:
        name.encode("utf-8")
        return name
    except UnicodeEncodeError:
        return name.encode("utf-8", "surrogateescape").decode("utf-8", "replace")


# ── Directory listing helpers ─────────────────────────────────────────────

def _cache_get(cache: OrderedDict, key, signature):
    with _cache_lock:
        hit = cache.get(key)
        if hit is None or hit[0] != signature or hit[1] < time.monotonic():
            return None
        cache.move_to_end(key)
        return hit


def _cache_put(cache: OrderedDict, key, value: tuple, max_entries: int) -> None:
    with _cache_lock:
        cache[key] = value
        cache.move_to_end(key)
        while len(cache) > max_entries:
            cache.popitem(last=False)


def _list_directory(real_dir: str, dir_stat: os.stat_result) -> tuple:
    """Sorted visible folder and file names of a directory, without stat()ing every file.
    Reused for a minute while the directory's mtime is unchanged, so paging through a
    50k-file folder doesn't re-list it for every page."""
    signature = (dir_stat.st_ino, dir_stat.st_mtime_ns)
    hit = _cache_get(_listing_cache, real_dir, signature)
    if hit is not None:
        return hit[2], hit[3]

    root_real = storage_root_real()
    folders, files = [], []
    with os.scandir(real_dir) as it:
        for entry in it:
            name = entry.name
            if name.startswith('.'):
                continue
            try:
                if entry.is_symlink():
                    target = os.path.realpath(entry.path)
                    # Never list links that leave the storage root (or dangle)
                    if not is_within(target, root_real) or not os.path.exists(target):
                        continue
                    is_dir = os.path.isdir(target)
                else:
                    is_dir = entry.is_dir(follow_symlinks=False)
            except OSError:
                continue
            (folders if is_dir else files).append(name)
    folders.sort()
    files.sort()
    _cache_put(_listing_cache, real_dir, (signature, time.monotonic() + _LISTING_TTL, folders, files), _LISTING_CACHE_MAX)
    return folders, files


def _children_count(real_dir: str, dir_stat: os.stat_result) -> int:
    """Visible entries in a folder; cached per folder mtime (one readdir per folder otherwise)."""
    signature = (dir_stat.st_ino, dir_stat.st_mtime_ns)
    hit = _cache_get(_count_cache, real_dir, signature)
    if hit is not None:
        return hit[2]
    try:
        with os.scandir(real_dir) as it:
            count = sum(1 for entry in it if not entry.name.startswith('.'))
    except OSError:
        count = 0
    _cache_put(_count_cache, real_dir, (signature, time.monotonic() + _COUNT_TTL, count), _COUNT_CACHE_MAX)
    return count


def _media_ids_for(full_paths: list, db: Session) -> dict:
    """media_files.id by path for one page of files (batched IN queries, not one per file)."""
    found = {}
    try:
        for i in range(0, len(full_paths), _IN_QUERY_CHUNK):
            chunk = full_paths[i:i + _IN_QUERY_CHUNK]
            for media_id, path in db.query(MediaFile.id, MediaFile.path).filter(MediaFile.path.in_(chunk)):
                found[path] = media_id
    except Exception as e:
        logger.warning(f"media_id lookup failed: {e}")
    return found


@router.get("/browse")
def browse_directory(
    path: str = Query("", description="Relative path from storage root"),
    page: int = Query(1, ge=1),
    per_page: int = Query(200, ge=1, le=1000),
    db: Session = Depends(get_db),
):
    """
    Browse a directory in the NAS filesystem.
    Paginated for large directories on weak hardware: only the files on the requested
    page are stat()ed. Folders are always returned in full.
    """
    clean_path, _full_path, real_path = resolve_storage_path(path)

    try:
        dir_stat = os.stat(real_path)
    except OSError:
        raise HTTPException(status_code=404, detail="Directory not found")
    if not stat.S_ISDIR(dir_stat.st_mode):
        raise HTTPException(status_code=400, detail="Not a directory")

    try:
        folder_names, file_names = _list_directory(real_path, dir_stat)
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")
    except OSError as e:
        logger.error(f"Error listing directory {real_path}: {e}")
        raise HTTPException(status_code=500, detail="Cannot read directory")

    def relative(name: str) -> str:
        return f"{clean_path}/{name}" if clean_path else name

    folders = []
    for entry in folder_names:
        entry_real = os.path.join(real_path, entry)
        try:
            entry_stat = os.stat(entry_real)
        except OSError:
            continue
        folders.append({
            "name": _display(entry),
            "path": _display(relative(entry)),
            "type": "folder",
            "children_count": _children_count(entry_real, entry_stat),
            "modified": datetime.fromtimestamp(entry_stat.st_mtime).isoformat(),
        })

    # Paginate files (folders always shown in full since they're usually few)
    total_files = len(file_names)
    offset = (page - 1) * per_page
    files = []
    full_paths = []
    for entry in file_names[offset:offset + per_page]:
        try:
            entry_stat = os.stat(os.path.join(real_path, entry))
        except OSError:
            continue

        ext = os.path.splitext(entry)[1].lower()
        mime_type, _ = mimetypes.guess_type(entry)

        file_type = "other"
        if ext in IMAGE_EXTENSIONS:
            file_type = "image"
        elif ext in VIDEO_EXTENSIONS:
            file_type = "video"
        elif ext in DOCUMENT_TYPES:
            file_type = "document"

        files.append({
            "name": _display(entry),
            "path": _display(relative(entry)),
            "type": "file",
            "file_type": file_type,
            "extension": _display(ext),
            "mime_type": mime_type,
            "size": entry_stat.st_size,
            "size_human": _format_size(entry_stat.st_size),
            "modified": datetime.fromtimestamp(entry_stat.st_mtime).isoformat(),
            "media_id": None,
        })
        full_paths.append(os.path.join(STORAGE_PATH, relative(entry)))

    # Timeline id of each file (lets the web Finder open files in the media viewer)
    media_ids = _media_ids_for(full_paths, db) if full_paths else {}
    for file_entry, full in zip(files, full_paths):
        file_entry["media_id"] = media_ids.get(full)

    # Build breadcrumb
    breadcrumb = [{"name": "Storage", "path": ""}]
    if clean_path:
        parts = clean_path.split("/")
        for i, part in enumerate(parts):
            breadcrumb.append({
                "name": _display(part),
                "path": _display("/".join(parts[:i + 1])),
            })

    return {
        "current_path": _display(clean_path) if clean_path else "/",
        "breadcrumb": breadcrumb,
        "folders": folders,
        "files": files,
        "total_folders": len(folders),
        "total_files": total_files,
        "page": page,
        "per_page": per_page,
    }


@router.get("/download")
@router.head("/download", include_in_schema=False)
def download_file(request: Request, path: str = Query(..., description="Relative path from storage root")):
    """Download a file from the NAS storage. Supports Range (resume / seek), HEAD and 304."""
    _clean_path, full_path, real_path = resolve_storage_path(path)
    try:
        file_stat = os.stat(real_path)
    except OSError:
        raise HTTPException(status_code=404, detail="File not found")
    if not stat.S_ISREG(file_stat.st_mode):
        raise HTTPException(status_code=400, detail="Not a file")

    filename = _display(os.path.basename(full_path))
    mime_type, _ = mimetypes.guess_type(full_path)
    return cached_file_response(
        request, real_path, mime_type or "application/octet-stream", FILE_CACHE_CONTROL, file_stat,
        filename=filename,
    )


def _queued_response() -> Response:
    # Contract with the Mac/iOS loaders: 202 = queued on the NAS worker, poll again after Retry-After.
    return Response(
        content=b'{"status":"queued"}',
        status_code=202,
        media_type="application/json",
        headers={"Retry-After": "2", "Cache-Control": "no-store"},
    )


def _same_file(path: str, source_stat: os.stat_result) -> bool:
    try:
        other = os.stat(path)
    except OSError:
        return False
    return (other.st_dev, other.st_ino) == (source_stat.st_dev, source_stat.st_ino)


def _canonical_for_mirror(clean_path: str, source_stat: os.stat_result) -> Optional[str]:
    """Full path of the canonical Vault file a Mirrors/ hardlink points at (same inode), or None."""
    full_mirror = os.path.join(STORAGE_PATH, clean_path)
    with _cache_lock:
        cached = _alias_cache.get(full_mirror)
    # Re-check the inode: a mirror can be re-linked to different content later
    if cached is not None and (cached == "" or _same_file(cached, source_stat)):
        return cached or None

    canonical = ""
    try:
        from database import SessionLocal
        with SessionLocal() as db:
            rows = db.execute(
                text("""
                    SELECT DISTINCT po.physical_path
                    FROM logical_items li
                    JOIN physical_objects po ON li.physical_object_id = po.id
                    WHERE li.original_filename = :fn
                    LIMIT 64
                """),
                {"fn": os.path.basename(clean_path)},
            ).fetchall()
        for (physical_path,) in rows:
            candidate = os.path.join(STORAGE_PATH, physical_path)
            # Same inode = the hardlink really is this file (a filename match alone is not enough:
            # IMG_0001.JPG exists once per year on every iPhone).
            if _same_file(candidate, source_stat):
                canonical = candidate
                break
    except Exception as db_err:
        logger.debug(f"Mirror lookup failed: {db_err}")
        return None
    _cache_put(_alias_cache, full_mirror, canonical, _ALIAS_CACHE_MAX)
    return canonical or None


def _alias_source(clean_path: str, full_path: str, real_path: str, source_stat: os.stat_result) -> Optional[str]:
    """Another path whose thumbnail is valid for this file: the target of a symlink inside the
    storage root, or the canonical Vault object behind a Mirrors/ hardlink."""
    rel_target = os.path.relpath(real_path, storage_root_real())
    if rel_target != clean_path:
        return os.path.join(STORAGE_PATH, rel_target)
    if clean_path.startswith("Mirrors/") and source_stat.st_nlink > 1:
        return _canonical_for_mirror(clean_path, source_stat)
    return None


@router.get("/thumbnail")
@router.head("/thumbnail", include_in_schema=False)
def get_file_thumbnail(request: Request, path: str = Query(..., description="Relative path from storage root")):
    """
    Get or enqueue a lightweight WebP thumbnail for a file on the NAS.
    Optimized for Core 2 Duo NAS hardware:
    1. Fast path: checks deterministic disk cache first (0% CPU, instantaneous file response).
    2. Fallback: the media_files row's thumbnail, or the canonical Vault thumbnail for symlinks
       and Mirrors/ hardlinks (shared, so a mirror never triggers a second decode).
    3. On-demand: enqueues to the background LIFO worker and answers 202 + Retry-After
       (never transcodes in the request thread). Files that failed recently answer 404.
    4. HTTP caching: ETag/Last-Modified + Cache-Control; revalidation returns 304.
    An optional `size` query param (sent by iOS) is accepted and ignored.
    """
    clean_path, full_path, real_path = resolve_storage_path(path)
    try:
        source_stat = os.stat(real_path)
    except OSError:
        raise HTTPException(status_code=404, detail="File not found")
    if not stat.S_ISREG(source_stat.st_mode):
        raise HTTPException(status_code=400, detail="Not a file")

    # 1. Deterministic thumbnail path from storage path
    thumb_path = get_thumbnail_path(full_path)
    thumb_stat = find_fresh_thumbnail(thumb_path, source_stat)

    # 2. Check if clean_path itself was hashed (legacy key)
    if thumb_stat is None:
        alt_thumb_path = get_thumbnail_path(clean_path)
        alt_stat = find_fresh_thumbnail(alt_thumb_path, source_stat)
        if alt_stat is not None:
            thumb_path, thumb_stat = alt_thumb_path, alt_stat
    if thumb_stat is not None:
        return cached_file_response(request, thumb_path, "image/webp", THUMBNAIL_CACHE_CONTROL, thumb_stat)

    # Already queued or generating: answer immediately, without DB lookups on every poll
    if is_thumbnail_pending(full_path):
        return _queued_response()

    # 3. Media extensions check
    ext = os.path.splitext(full_path)[1].lower()
    if ext not in THUMBNAIL_EXTENSIONS:
        raise HTTPException(status_code=404, detail="File type does not support thumbnails")

    # 4. Thumbnail generated for this file under another path
    try:
        from database import SessionLocal
        with SessionLocal() as db:
            media = db.query(MediaFile).filter(MediaFile.path == full_path).first()
            recorded = media.thumbnail_path if media else None
        if recorded and recorded != thumb_path:
            recorded_stat = find_fresh_thumbnail(recorded, source_stat)
            if recorded_stat is not None:
                return cached_file_response(request, recorded, "image/webp", THUMBNAIL_CACHE_CONTROL, recorded_stat)
    except Exception as db_err:
        logger.debug(f"Database lookup failed: {db_err}")

    alias = _alias_source(clean_path, full_path, real_path, source_stat)
    if alias:
        alias_thumb = get_thumbnail_path(alias)
        alias_stat = find_fresh_thumbnail(alias_thumb, source_stat)
        if alias_stat is not None:
            # Materialize it under this path's key too, so the next request takes the fast path
            if link_thumbnail(alias_thumb, thumb_path):
                linked_stat = find_fresh_thumbnail(thumb_path, source_stat)
                if linked_stat is not None:
                    return cached_file_response(request, thumb_path, "image/webp", THUMBNAIL_CACHE_CONTROL, linked_stat)
            return cached_file_response(request, alias_thumb, "image/webp", THUMBNAIL_CACHE_CONTROL, alias_stat)
        if thumbnail_failed(alias, source_stat):
            raise HTTPException(status_code=404, detail="Thumbnail could not be generated")
        # Generate once under the canonical key; every mirror of it then shares the result
        schedule_thumbnail(alias, alias_thumb)
        return _queued_response()

    if thumbnail_failed(full_path, source_stat):
        raise HTTPException(status_code=404, detail="Thumbnail could not be generated")

    # 5. Non-blocking background enqueue: return 202 Accepted immediately
    # Never transcode heavy 4K videos or 48MP HEICs synchronously in HTTP request workers!
    schedule_thumbnail(full_path, thumb_path)
    return _queued_response()


@router.get("/tree")
def get_directory_tree(depth: int = Query(2, ge=1, le=4)):
    """Get a directory tree structure up to specified depth.
    Limited depth (and at most 5000 folders, cached for 30s) to avoid slow responses on NAS.
    Uses scandir so files are never stat()ed; hidden folders and links leaving the storage
    root are skipped."""
    cached = _tree_cache.get(depth)
    if cached is not None and cached[0] > time.monotonic():
        return {"tree": cached[1]}

    root_real = storage_root_real()
    budget = [_TREE_MAX_NODES]

    def build_tree(real_dir: str, rel_dir: str, current_depth: int) -> list:
        if current_depth <= 0 or budget[0] <= 0:
            return []

        names = []
        try:
            with os.scandir(real_dir) as it:
                for entry in it:
                    if entry.name.startswith('.'):
                        continue
                    try:
                        if entry.is_symlink():
                            if not entry.is_dir() or not is_within(os.path.realpath(entry.path), root_real):
                                continue
                        elif not entry.is_dir(follow_symlinks=False):
                            continue
                    except OSError:
                        continue
                    names.append(entry.name)
        except OSError:
            return []

        result = []
        for name in sorted(names):
            if budget[0] <= 0:
                break
            budget[0] -= 1
            relative = f"{rel_dir}/{name}" if rel_dir else name
            result.append({
                "name": _display(name),
                "path": _display(relative),
                "type": "folder",
                "children": build_tree(os.path.join(real_dir, name), relative, current_depth - 1),
            })

        return result

    tree = build_tree(root_real, "", depth)
    _tree_cache[depth] = (time.monotonic() + _TREE_TTL, tree)
    return {"tree": tree}


def _format_size(size_bytes: int) -> str:
    """Format bytes to human readable string."""
    if size_bytes == 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    size = float(size_bytes)
    while size >= 1024 and i < len(units) - 1:
        size /= 1024
        i += 1
    return f"{size:.1f} {units[i]}"
