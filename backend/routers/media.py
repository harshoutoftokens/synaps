"""
Synaps Media Router — Timeline & media APIs
"""
from fastapi import APIRouter, Depends, Query, HTTPException, Request
from fastapi.responses import FileResponse, Response
from sqlalchemy.orm import Session
from sqlalchemy import func, desc
from typing import Optional
from datetime import datetime
from email.utils import formatdate, parsedate_to_datetime

from database import get_db
from models import MediaFile
from config import ARCHIVE_CUTOFF_YEAR
from thumbnails import (
    get_thumbnail_path, find_fresh_thumbnail, schedule_thumbnail, thumbnail_failed,
    ensure_preview, PreviewBusy, HEIC_EXTENSIONS,
)
import os
import hashlib
import mimetypes
import logging

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api/media", tags=["media"])

SVG_PLACEHOLDER = b"""<svg width="320" height="320" xmlns="http://www.w3.org/2000/svg">
  <rect width="320" height="320" fill="#1f2937"/>
  <text x="50%" y="50%" font-family="system-ui, sans-serif" font-size="14" fill="#9ca3af" text-anchor="middle" dominant-baseline="middle">Generating...</text>
</svg>"""

# Browser cache lifetimes. Thumbnail/file URLs are keyed by media id or path (not by content),
# so they get max-age + validators (ETag/Last-Modified → 304) rather than "immutable".
THUMBNAIL_CACHE_CONTROL = "private, max-age=604800"
FILE_CACHE_CONTROL = "private, max-age=86400"


# ── Conditional/cached file responses (shared with finder.py and trash.py) ──

def file_etag(st: os.stat_result) -> str:
    """Strong validator for a file on disk; changes whenever the file is rewritten."""
    raw = f"{st.st_ino}-{st.st_mtime_ns}-{st.st_size}".encode()
    return '"' + hashlib.md5(raw).hexdigest() + '"'


def is_not_modified(request: Request, etag: str, mtime: float) -> bool:
    """RFC 9110 conditional GET: If-None-Match wins over If-Modified-Since."""
    if_none_match = request.headers.get("if-none-match")
    if if_none_match is not None:
        if if_none_match.strip() == "*":
            return True
        tags = [tag.strip() for tag in if_none_match.split(",")]
        return etag in tags or etag in [tag.removeprefix("W/") for tag in tags]
    if_modified_since = request.headers.get("if-modified-since")
    if if_modified_since:
        try:
            return int(mtime) <= parsedate_to_datetime(if_modified_since).timestamp()
        except (TypeError, ValueError, IndexError, OverflowError):
            return False
    return False


def cached_file_response(
    request: Request,
    path: str,
    media_type: str,
    cache_control: str,
    stat_result: Optional[os.stat_result] = None,
    filename: Optional[str] = None,
) -> Response:
    """FileResponse with ETag/Last-Modified/Cache-Control that answers revalidations with 304.
    FileResponse itself handles HEAD and Range (206 / Content-Range / Accept-Ranges)."""
    st = stat_result or os.stat(path)
    etag = file_etag(st)
    headers = {
        "ETag": etag,
        "Last-Modified": formatdate(st.st_mtime, usegmt=True),
        "Cache-Control": cache_control,
    }
    if is_not_modified(request, etag, st.st_mtime):
        return Response(status_code=304, headers=headers)
    return FileResponse(path, media_type=media_type, headers=headers, stat_result=st, filename=filename)


def _placeholder_response() -> Response:
    # The web grid polls this URL with HEAD until the content-type stops being SVG.
    return Response(
        content=SVG_PLACEHOLDER,
        media_type="image/svg+xml",
        headers={"Cache-Control": "no-store", "Retry-After": "2"},
    )


@router.get("")
@router.get("/")
@router.get("/timeline")  # Keep for backwards compatibility if needed
def get_media_browser(
    view: str = Query("timeline", description="View type: 'timeline' or 'gallery'"),
    sources: Optional[str] = Query(None, description="Comma-separated list of sources, e.g. 'iphone,mac'"),
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    media_type: Optional[str] = Query(None),
    year: Optional[int] = Query(None),
    month: Optional[int] = Query(None),
    db: Session = Depends(get_db),
):
    """
    Get media grouped by month/year for timeline view, or flat for gallery view.
    Returns media sorted by date_taken descending.
    """
    query = db.query(MediaFile)

    # Apply filters
    if sources:
        source_list = [s.strip().lower() for s in sources.split(",")]
        query = query.filter(MediaFile.source.in_(source_list))

    if media_type:
        if media_type == "screenshot":
            query = query.filter(MediaFile.is_screenshot == True)
        elif media_type == "screen_recording":
            query = query.filter(MediaFile.is_screen_recording == True)
        elif media_type == "raw":
            query = query.filter(MediaFile.is_raw == True)
        elif media_type == "favorite":
            query = query.filter(MediaFile.is_favorite == True)
        else:
            query = query.filter(MediaFile.media_type == media_type)

    # Date filters as ranges on date_taken so SQLite can use its index
    # (strftime() on the column forces a full table scan).
    if year and 1 <= year <= 9998 and (not month or 1 <= month <= 12):
        if month:
            start = datetime(year, month, 1)
            end = datetime(year + 1, 1, 1) if month == 12 else datetime(year, month + 1, 1)
        else:
            start, end = datetime(year, 1, 1), datetime(year + 1, 1, 1)
        query = query.filter(MediaFile.date_taken >= start, MediaFile.date_taken < end)
    else:
        if year:
            query = query.filter(func.strftime("%Y", MediaFile.date_taken) == str(year))
        if month:
            query = query.filter(func.strftime("%m", MediaFile.date_taken) == f"{month:02d}")

    total = query.count()
    offset = (page - 1) * per_page
    items = query.order_by(desc(MediaFile.date_taken)).offset(offset).limit(per_page).all()

    if view == "gallery":
        flat_items = []
        for item in items:
            serialized = _serialize_media(item)
            dt = item.date_taken or item.date_created or datetime.now()
            # For the sticky header: '16 May 2026'
            serialized["date_string"] = dt.strftime("%-d %B %Y")
            flat_items.append(serialized)

        return {
            "items": flat_items,
            "total": total,
            "page": page,
            "per_page": per_page,
            "total_pages": (total + per_page - 1) // per_page if per_page > 0 else 0,
        }

    # Timeline View: Group by month/year
    groups = {}
    for item in items:
        dt = item.date_taken or item.date_created or datetime.now()

        # Check if it's an Old Photo (Archive)
        if dt.year < ARCHIVE_CUTOFF_YEAR:
            key = "Old_Photos"
            if key not in groups:
                groups[key] = {
                    "year": 0,  # 0 sorts to the bottom
                    "month": 0,
                    "month_name": "Archive",
                    "items": [],
                }
            groups[key]["items"].append(_serialize_media(item))
            continue

        key = dt.strftime("%Y-%m")
        if key not in groups:
            groups[key] = {
                "year": dt.year,
                "month": dt.month,
                "month_name": dt.strftime("%B"),
                "items": [],
            }
        groups[key]["items"].append(_serialize_media(item))

    # Sort groups by date descending
    sorted_groups = sorted(groups.values(), key=lambda g: (g["year"], g["month"]), reverse=True)

    return {
        "groups": sorted_groups,
        "total": total,
        "page": page,
        "per_page": per_page,
        "total_pages": (total + per_page - 1) // per_page if per_page > 0 else 0,
    }


@router.get("/item/{media_id}")
def get_media_item(media_id: str, db: Session = Depends(get_db)):
    """Get a single media item by ID."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")
    return _serialize_media(item, full=True)


@router.get("/thumbnail/{media_id}")
@router.head("/thumbnail/{media_id}", include_in_schema=False)
def get_thumbnail(media_id: str, request: Request, db: Session = Depends(get_db)):
    """Get or generate a thumbnail for a media file.
    Ready: WebP with ETag/Last-Modified (304 on revalidation).
    Not ready: SVG placeholder while the background worker generates it (never blocks).
    Source missing or generation failed: 404, so pollers stop and show their fallback."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")

    try:
        source_stat = os.stat(item.path)
    except OSError:
        source_stat = None

    # Check cached thumbnail (deterministic key, then the path recorded by the worker)
    thumb_path = get_thumbnail_path(item.path)
    thumb_stat = find_fresh_thumbnail(thumb_path, source_stat)
    if thumb_stat is None and item.thumbnail_path and item.thumbnail_path != thumb_path:
        thumb_stat = find_fresh_thumbnail(item.thumbnail_path, source_stat)
        if thumb_stat is not None:
            thumb_path = item.thumbnail_path
    if thumb_stat is not None:
        return cached_file_response(request, thumb_path, "image/webp", THUMBNAIL_CACHE_CONTROL, thumb_stat)

    if source_stat is None:
        raise HTTPException(status_code=404, detail="File not found on disk")
    if thumbnail_failed(item.path, source_stat):
        raise HTTPException(status_code=404, detail="Thumbnail could not be generated")

    # Enqueue on-the-fly generation asynchronously
    schedule_thumbnail(item.path, get_thumbnail_path(item.path))

    # Return an SVG placeholder so frontend doesn't hang
    return _placeholder_response()


@router.get("/file/{media_id}")
@router.head("/file/{media_id}", include_in_schema=False)
def get_file(
    media_id: str,
    request: Request,
    original: bool = Query(False, description="Serve the original bytes even for HEIC (no JPEG preview)"),
    db: Session = Depends(get_db),
):
    """Serve the original file. HEIC/HEIF (which browsers can't render) is served as a cached
    JPEG preview of at most 2560 px unless ?original=1. Supports Range, HEAD and 304."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")
    try:
        st = os.stat(item.path)
    except OSError:
        logger.error(f"Failed to serve file - not found on disk: {item.path}")
        raise HTTPException(status_code=404, detail="File not found on disk")

    # Always compute the file extension for downstream decisions
    ext = (item.extension or os.path.splitext(item.filename)[1] or "").lower()

    # HEIC: convert once (≤2560 px JPEG), cache on disk keyed by path+mtime+size, then serve
    # the cached file like any other (the old code re-transcoded on every request).
    if ext in HEIC_EXTENSIONS and not original:
        try:
            preview_path = ensure_preview(item.path, st)
            preview_name = os.path.splitext(item.filename or "image")[0] + ".jpg"
            return cached_file_response(request, preview_path, "image/jpeg", FILE_CACHE_CONTROL, filename=preview_name)
        except PreviewBusy:
            raise HTTPException(status_code=503, detail="Preview converter busy", headers={"Retry-After": "5"})
        except Exception as e:
            logger.error(f"HEIC transcode failed for {item.filename}: {e}")
            # Fall through to serve raw file as last resort

    # Resolve correct MIME type for non-HEIC files
    mime_type = _resolve_mime(item, ext)
    return cached_file_response(request, item.path, mime_type, FILE_CACHE_CONTROL, st, filename=item.filename)


@router.get("/stream/{media_id}")
@router.head("/stream/{media_id}", include_in_schema=False)
def stream_video(media_id: str, request: Request, db: Session = Depends(get_db)):
    """Stream a video file (HTTP Range → 206, so players can seek)."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")
    try:
        st = os.stat(item.path)
    except OSError:
        raise HTTPException(status_code=404, detail="File not found on disk")

    ext = (item.extension or os.path.splitext(item.filename)[1] or "").lower()
    mime_type = _resolve_mime(item, ext)
    return cached_file_response(request, item.path, mime_type, FILE_CACHE_CONTROL, st, filename=item.filename)


def _resolve_mime(item, ext: str) -> str:
    """Resolve a reliable MIME type from DB value, mimetypes module, or extension fallback."""
    mime = item.mime_type
    if mime and mime != "application/octet-stream":
        return mime
    # Try the stdlib guesser with lowercased filename
    guessed, _ = mimetypes.guess_type(item.filename.lower())
    if guessed:
        return guessed
    # Manual fallback map
    fallback = {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".png": "image/png", ".gif": "image/gif", ".webp": "image/webp",
        ".heic": "image/heic", ".heif": "image/heif",
        ".mp4": "video/mp4", ".mov": "video/quicktime",
        ".m4v": "video/x-m4v", ".avi": "video/x-msvideo",
    }
    return fallback.get(ext, "application/octet-stream")


@router.post("/favorite/{media_id}")
def toggle_favorite(media_id: str, db: Session = Depends(get_db)):
    """Toggle favorite status for a media item."""
    item = db.query(MediaFile).filter(MediaFile.id == media_id).first()
    if not item:
        raise HTTPException(status_code=404, detail="Media not found")
    item.is_favorite = not item.is_favorite
    db.commit()
    return {"id": media_id, "is_favorite": item.is_favorite}


def library_counts(db: Session) -> dict:
    """Library counters shared by /api/media/stats and /api/settings/storage-usage.
    Separate COUNT queries are deliberate: each is a covering-index scan in SQLite, which
    measured faster than one CASE-per-row table scan. sum(file_size) is the one full scan."""
    return {
        "total": db.query(MediaFile).count(),
        "images": db.query(MediaFile).filter(MediaFile.media_type == "image").count(),
        "videos": db.query(MediaFile).filter(MediaFile.media_type == "video").count(),
        "documents": db.query(MediaFile).filter(MediaFile.media_type == "document").count(),
        "screenshots": db.query(MediaFile).filter(MediaFile.is_screenshot == True).count(),
        "favorites": db.query(MediaFile).filter(MediaFile.is_favorite == True).count(),
        "total_size": db.query(func.sum(MediaFile.file_size)).scalar() or 0,
    }


@router.get("/stats")
def get_stats(db: Session = Depends(get_db)):
    """Get media library statistics."""
    counts = library_counts(db)
    total_size = counts["total_size"]

    return {
        "total_files": counts["total"],
        "images": counts["images"],
        "videos": counts["videos"],
        "documents": counts["documents"],
        "screenshots": counts["screenshots"],
        "favorites": counts["favorites"],
        "total_size_bytes": total_size,
        "total_size_human": _format_size(total_size),
    }


def _serialize_media(item: MediaFile, full: bool = False) -> dict:
    """Serialize a MediaFile to a dict."""
    data = {
        "id": item.id,
        "filename": item.filename,
        "media_type": item.media_type,
        "extension": item.extension,
        "file_size": item.file_size,
        "file_size_human": _format_size(item.file_size),
        "width": item.width,
        "height": item.height,
        "is_screenshot": item.is_screenshot,
        "is_favorite": item.is_favorite,
        "date_taken": item.date_taken.isoformat() if item.date_taken else None,
        "has_thumbnail": item.has_thumbnail,
        "thumbnail_url": f"/api/media/thumbnail/{item.id}",
        "file_url": f"/api/media/file/{item.id}",
    }

    if item.media_type == "video":
        data["stream_url"] = f"/api/media/stream/{item.id}"
        data["duration"] = item.duration

    if full:
        data.update({
            "path": item.relative_path,
            "directory": item.directory,
            "mime_type": item.mime_type,
            "date_created": item.date_created.isoformat() if item.date_created else None,
            "date_modified": item.date_modified.isoformat() if item.date_modified else None,
            "camera_make": item.camera_make,
            "camera_model": item.camera_model,
            "gps_lat": item.gps_lat,
            "gps_lon": item.gps_lon,
        })

    return data


def _format_size(size_bytes: int) -> str:
    """Format bytes to human readable string."""
    if not size_bytes:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    size = float(size_bytes)
    while size >= 1024 and i < len(units) - 1:
        size /= 1024
        i += 1
    return f"{size:.1f} {units[i]}"
