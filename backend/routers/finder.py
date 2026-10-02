"""
Synaps Finder Router — Directory browsing APIs
Optimized for low-power NAS with paginated responses.
"""
from fastapi import APIRouter, Query, HTTPException
from fastapi.responses import FileResponse
from typing import Optional
import os
import mimetypes
import logging
from datetime import datetime

from config import STORAGE_PATH, ALL_EXTENSIONS, IMAGE_EXTENSIONS, VIDEO_EXTENSIONS
<<<<<<< HEAD
from thumbnails import get_thumbnail_path, enqueue_thumbnail, generate_image_thumbnail, generate_video_thumbnail
=======
from thumbnails import get_thumbnail_path, enqueue_thumbnail, generate_image_thumbnail
>>>>>>> origin/main

logger = logging.getLogger("synaps.finder")

router = APIRouter(prefix="/api/finder", tags=["finder"])


@router.get("/browse")
def browse_directory(
    path: str = Query("", description="Relative path from storage root"),
    page: int = Query(1, ge=1),
    per_page: int = Query(200, ge=1, le=1000),
):
    """
    Browse a directory in the NAS filesystem.
    Paginated for large directories on weak hardware.
    """
    # Sanitize path to prevent directory traversal
    clean_path = os.path.normpath(path).lstrip("/")
    if ".." in clean_path:
        raise HTTPException(status_code=400, detail="Invalid path")

    full_path = os.path.join(STORAGE_PATH, clean_path) if clean_path and clean_path != '.' else STORAGE_PATH

    if not os.path.exists(full_path):
        raise HTTPException(status_code=404, detail="Directory not found")

    if not os.path.isdir(full_path):
        raise HTTPException(status_code=400, detail="Not a directory")

    try:
        entries = sorted(os.listdir(full_path))
    except PermissionError:
        raise HTTPException(status_code=403, detail="Permission denied")
    except OSError as e:
        logger.error(f"Error listing directory {full_path}: {e}")
        raise HTTPException(status_code=500, detail="Cannot read directory")

    folders = []
    files = []

    for entry in entries:
        if entry.startswith('.'):
            continue

        entry_path = os.path.join(full_path, entry)
        relative_entry = os.path.join(clean_path, entry) if clean_path and clean_path != '.' else entry

        try:
            stat = os.stat(entry_path)
        except OSError:
            continue

        if os.path.isdir(entry_path):
            # Count children without recursive scanning
            try:
                child_count = len([c for c in os.listdir(entry_path) if not c.startswith('.')])
            except OSError:
                child_count = 0

            folders.append({
                "name": entry,
                "path": relative_entry,
                "type": "folder",
                "children_count": child_count,
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })
        else:
            ext = os.path.splitext(entry)[1].lower()
            mime_type, _ = mimetypes.guess_type(entry_path)

            file_type = "other"
            if ext in IMAGE_EXTENSIONS:
                file_type = "image"
            elif ext in VIDEO_EXTENSIONS:
                file_type = "video"
            elif ext in {".pdf", ".doc", ".docx", ".txt", ".md"}:
                file_type = "document"

            files.append({
                "name": entry,
                "path": relative_entry,
                "type": "file",
                "file_type": file_type,
                "extension": ext,
                "mime_type": mime_type,
                "size": stat.st_size,
                "size_human": _format_size(stat.st_size),
                "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
            })

    # Build breadcrumb
    breadcrumb = [{"name": "Storage", "path": ""}]
    if clean_path and clean_path != '.':
        parts = clean_path.split(os.sep)
        for i, part in enumerate(parts):
            breadcrumb.append({
                "name": part,
                "path": os.sep.join(parts[:i + 1]),
            })

    # Paginate files (folders always shown in full since they're usually few)
    total_files = len(files)
    offset = (page - 1) * per_page
    paginated_files = files[offset:offset + per_page]

    return {
        "current_path": clean_path if clean_path and clean_path != '.' else "/",
        "breadcrumb": breadcrumb,
        "folders": folders,
        "files": paginated_files,
        "total_folders": len(folders),
        "total_files": total_files,
        "page": page,
        "per_page": per_page,
    }


@router.get("/download")
def download_file(path: str = Query(..., description="Relative path from storage root")):
    """Download a file from the NAS storage."""
    clean_path = os.path.normpath(path).lstrip("/")
    if ".." in clean_path:
        raise HTTPException(status_code=400, detail="Invalid path")

    full_path = os.path.join(STORAGE_PATH, clean_path)
    if not os.path.exists(full_path):
        raise HTTPException(status_code=404, detail="File not found")
    if not os.path.isfile(full_path):
        raise HTTPException(status_code=400, detail="Not a file")

    filename = os.path.basename(full_path)
    mime_type, _ = mimetypes.guess_type(full_path)
    return FileResponse(
        full_path,
        media_type=mime_type or "application/octet-stream",
        filename=filename,
    )


@router.get("/thumbnail")
def get_file_thumbnail(path: str = Query(..., description="Relative path from storage root")):
    """
    Get or enqueue a lightweight WebP thumbnail for a file on the NAS.
    Optimized for Core 2 Duo NAS hardware:
    1. Fast path: checks deterministic disk cache first (0% CPU, instantaneous file response).
    2. Fallback: queries database for indexed thumbnail path if stored under an alias.
    3. On-demand: enqueues to single background LIFO worker (never overwhelms NAS CPU/RAM).
    4. HTTP caching: sets Cache-Control so the Mac client caches to SSD permanently.
    """
    clean_path = os.path.normpath(path).lstrip("/")
    if ".." in clean_path:
        raise HTTPException(status_code=400, detail="Invalid path")

    full_path = os.path.join(STORAGE_PATH, clean_path)
    if not os.path.exists(full_path):
        raise HTTPException(status_code=404, detail="File not found")
    if not os.path.isfile(full_path):
        raise HTTPException(status_code=400, detail="Not a file")

    # 1. Deterministic thumbnail path from storage path
    thumb_path = get_thumbnail_path(full_path)
    if os.path.exists(thumb_path):
        return FileResponse(
            thumb_path,
            media_type="image/webp",
            headers={"Cache-Control": "public, max-age=604800, immutable"}
        )

    # 2. Check if clean_path itself was hashed
    alt_thumb_path = get_thumbnail_path(clean_path)
    if os.path.exists(alt_thumb_path):
        return FileResponse(
            alt_thumb_path,
            media_type="image/webp",
            headers={"Cache-Control": "public, max-age=604800, immutable"}
        )

    # 3. Check database record if available
    try:
        from database import SessionLocal
        from models import MediaFile
        with SessionLocal() as db:
            media = db.query(MediaFile).filter(
                (MediaFile.relative_path == clean_path) | (MediaFile.path == full_path)
            ).first()
            if media and media.thumbnail_path and os.path.exists(media.thumbnail_path):
                return FileResponse(
                    media.thumbnail_path,
                    media_type="image/webp",
                    headers={"Cache-Control": "public, max-age=604800, immutable"}
                )
    except Exception as db_err:
        logger.debug(f"Database lookup failed: {db_err}")

    # 4. Media extensions check
    ext = os.path.splitext(full_path)[1].lower()
    media_exts = ALL_EXTENSIONS | {".heic", ".heif", ".mov", ".mp4", ".m4v", ".jpg", ".jpeg", ".png", ".webp", ".pdf"}
    if ext not in media_exts:
        raise HTTPException(status_code=404, detail="File type does not support thumbnails")

    # 5. Non-blocking background enqueue: return 202 Accepted immediately
    # Never transcode heavy 4K videos or 48MP HEICs synchronously in HTTP request workers!
    enqueue_thumbnail(full_path)
    from fastapi.responses import Response
    return Response(
        content=b'{"status":"queued"}',
        status_code=202,
        media_type="application/json",
        headers={"Retry-After": "2"}
    )


@router.get("/tree")
def get_directory_tree(depth: int = Query(2, ge=1, le=4)):
    """Get a directory tree structure up to specified depth.
    Limited depth to avoid slow responses on NAS."""
    def build_tree(path: str, current_depth: int) -> list:
        if current_depth <= 0:
            return []

        result = []
        try:
            entries = sorted(os.listdir(path))
        except (PermissionError, OSError):
            return []

        for entry in entries:
            if entry.startswith('.'):
                continue

            entry_path = os.path.join(path, entry)
            if os.path.isdir(entry_path):
                relative = os.path.relpath(entry_path, STORAGE_PATH)
                children = build_tree(entry_path, current_depth - 1)
                result.append({
                    "name": entry,
                    "path": relative,
                    "type": "folder",
                    "children": children,
                })

        return result

    tree = build_tree(STORAGE_PATH, depth)
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
