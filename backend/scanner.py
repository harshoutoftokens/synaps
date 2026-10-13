"""
Synaps Media Scanner — Async filesystem indexer
Designed for low-power hardware with batch processing.
"""
import os
import re
import hashlib
import mimetypes
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional

from sqlalchemy.orm import Session
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError

from config import (
    STORAGE_PATH, IMAGE_EXTENSIONS, VIDEO_EXTENSIONS,
    DOCUMENT_EXTENSIONS, RAW_EXTENSIONS, ALL_MEDIA_EXTENSIONS,
    SCAN_BATCH_SIZE, ALLOWED_SCAN_PATHS, SOURCE_MAPPING,
    EXCLUDED_PATHS, THUMBNAIL_DIR, TRASH_DIR
)
from models import MediaFile

logger = logging.getLogger("synaps.scanner")

# Never index the v2 hardlink mirrors (same inodes as the canonical Vault files) or the
# upload/trash staging areas, even if config.EXCLUDED_PATHS doesn't list them.
_BUILTIN_EXCLUDED_PATHS = ["Mirrors", ".synaps_tmp", ".synaps_trash"]

def _normalize_excluded(paths) -> list:
    normalized = []
    for p in paths:
        p = os.path.normpath(p.strip()).strip(os.sep)
        if p and p != "." and p not in normalized:  # "" or "." would exclude the whole storage
            normalized.append(p)
    return normalized


# Normalize excluded paths (relative to STORAGE_PATH, matched by whole path components)
NORMALIZED_EXCLUDED_PATHS = _normalize_excluded([*EXCLUDED_PATHS, *_BUILTIN_EXCLUDED_PATHS])

# Directory names that never hold user media
_SKIP_DIR_NAMES = {'thumbnails', 'trash', 'venv', '__pycache__', 'node_modules', '.git'}

# The garbage collection refuses to drop more than this share of the library in one scan
# (a half-mounted disk looks exactly like "every file was deleted").
GC_MAX_DELETE_FRACTION = 0.5
GC_MIN_ROWS_FOR_GUARD = 20

# v2 canonical layout: Vault/YYYY/MM/<sha256[:16]>_<name>
_V2_CANONICAL_RE = re.compile(r"^Vault/\d{4}/\d{2}/[^/]+$")
_V2_OBJECT_NAME_RE = re.compile(r"^Vault/\d{4}/\d{2}/[0-9a-f]{16}_[^/]+$")

# Try to import exifread for EXIF metadata
try:
    import exifread
    HAS_EXIFREAD = True
except ImportError:
    HAS_EXIFREAD = False
    logger.warning("exifread not installed — EXIF date extraction disabled")


def classify_media(ext: str, filename: str) -> dict:
    """Classify a file by its extension and name."""
    ext_lower = ext.lower()
    name_lower = filename.lower()

    media_type = "document"
    if ext_lower in IMAGE_EXTENSIONS:
        media_type = "image"
    elif ext_lower in VIDEO_EXTENSIONS:
        media_type = "video"

    # iPhone screenshots: iPhones save screenshots as PNG, regular photos as JPG/HEIC.
    # Detection: filename contains "screenshot", OR it's a PNG from an iPhone camera roll.
    # iPhone camera roll PNGs are almost always screenshots (iPhone never saves photos as PNG).
    import re
    is_iphone_png_screenshot = (
        ext_lower == ".png" and
        media_type == "image" and
        # Matches iPhone naming patterns: IMG_XXXX.PNG, 4-letter codes like AVGG4766.PNG, etc.
        bool(re.match(r'^(IMG_\d+|[A-Z]{4}\d{4})', filename))
    )

    is_screenshot = (
        "screenshot" in name_lower or
        "screen shot" in name_lower or
        name_lower.startswith("screenshot") or
        is_iphone_png_screenshot
    )

    is_screen_recording = (
        "screen recording" in name_lower or
        "screenrecording" in name_lower or
        ("screen" in name_lower and "recording" in name_lower)
    )

    is_raw = ext_lower in RAW_EXTENSIONS

    return {
        "media_type": media_type,
        "is_screenshot": is_screenshot,
        "is_screen_recording": is_screen_recording,
        "is_raw": is_raw,
    }


def compute_file_hash(filepath: str, chunk_size: int = 8192) -> str:
    """Compute a fast partial hash for deduplication.
    Only reads first 64KB for speed on low-power hardware."""
    hasher = hashlib.md5()
    try:
        with open(filepath, "rb") as f:
            # Read first 64KB for fast hashing
            data = f.read(65536)
            hasher.update(data)
    except (IOError, OSError):
        return ""
    return hasher.hexdigest()


def compute_content_hash(filepath: str, chunk_size: int = 65536) -> str:
    """Compute full SHA-256 hash for exact duplicate detection.
    Reads entire file in chunks."""
    hasher = hashlib.sha256()
    try:
        with open(filepath, "rb") as f:
            while True:
                chunk = f.read(chunk_size)
                if not chunk:
                    break
                hasher.update(chunk)
    except (IOError, OSError):
        return ""
    return hasher.hexdigest()


def extract_exif_date(filepath: str) -> Optional[datetime]:
    """Extract date taken from EXIF data.
    Uses exifread for JPEG/TIFF, and PIL+pillow_heif for HEIC files
    (exifread cannot read HEIC EXIF data)."""

    ext = os.path.splitext(filepath)[1].lower()

    # ── HEIC/HEIF: use PIL (with pillow-heif registered) ──
    if ext in {'.heic', '.heif'}:
        try:
            from PIL import Image
            from PIL.ExifTags import Base as ExifBase
            import pillow_heif
            pillow_heif.register_heif_opener()

            with Image.open(filepath) as img:
                exif_data = img.getexif()
                if exif_data:
                    # Tag 36867 = DateTimeOriginal, 306 = DateTime
                    date_str = exif_data.get(36867) or exif_data.get(306)
                    if date_str:
                        return datetime.strptime(date_str, "%Y:%m:%d %H:%M:%S")
        except Exception:
            pass
        return None

    # ── JPEG/TIFF/RAW: use exifread ──
    if not HAS_EXIFREAD:
        return None

    if ext not in {'.jpg', '.jpeg', '.tiff', '.raw', '.cr2', '.nef', '.arw', '.dng'}:
        return None

    try:
        with open(filepath, "rb") as f:
            tags = exifread.process_file(f, stop_tag="DateTimeOriginal", details=False)

        date_tag = tags.get("EXIF DateTimeOriginal") or tags.get("Image DateTime")
        if date_tag:
            date_str = str(date_tag)
            return datetime.strptime(date_str, "%Y:%m:%d %H:%M:%S")
    except Exception:
        pass
    return None


def extract_video_date(filepath: str) -> Optional[datetime]:
    """Extract creation date from video metadata using ffprobe.
    MP4/MOV files store creation_time in their container metadata."""
    import subprocess

    ext = os.path.splitext(filepath)[1].lower()
    if ext not in {'.mp4', '.mov', '.m4v'}:
        return None

    try:
        result = subprocess.run(
            [
                "ffprobe", "-v", "quiet",
                "-print_format", "json",
                "-show_entries", "format_tags=creation_time",
                filepath
            ],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode == 0:
            import json
            data = json.loads(result.stdout)
            creation_time = data.get("format", {}).get("tags", {}).get("creation_time")
            if creation_time:
                # Format: "2025-03-15T10:30:45.000000Z"
                clean = creation_time.replace("Z", "").split(".")[0]
                return datetime.strptime(clean, "%Y-%m-%dT%H:%M:%S")
    except (FileNotFoundError, subprocess.TimeoutExpired, Exception):
        pass
    return None


def extract_date_from_filename(filename: str) -> Optional[datetime]:
    """Try to extract date from common filename patterns like IMG_20230415_123456."""
    import re
    patterns = [
        r'(\d{4})[\-_](\d{2})[\-_](\d{2})',  # YYYY-MM-DD or YYYY_MM_DD
        r'(\d{4})(\d{2})(\d{2})',  # YYYYMMDD
    ]
    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            try:
                year, month, day = int(match.group(1)), int(match.group(2)), int(match.group(3))
                if 1990 <= year <= 2030 and 1 <= month <= 12 and 1 <= day <= 31:
                    return datetime(year, month, day)
            except (ValueError, IndexError):
                continue
    return None


def get_best_date(filepath: str, filename: str) -> datetime:
    """Get the best available date for a file.
    Priority: EXIF > video metadata > filename > filesystem."""
    # 1. Try EXIF (images)
    exif_date = extract_exif_date(filepath)
    if exif_date:
        return exif_date

    # 2. Try video container metadata (MP4/MOV)
    video_date = extract_video_date(filepath)
    if video_date:
        return video_date

    # 3. Try filename parsing
    fn_date = extract_date_from_filename(filename)
    if fn_date:
        return fn_date

    # Fallback to filesystem dates
    # Priority: birthtime (original creation) > mtime (last modified)
    # Why: When files are copied/transferred between devices, mtime is reset
    # to the copy date. birthtime preserves the original creation timestamp
    # on macOS (HFS+/APFS) and some NAS filesystems.
    try:
        stat = os.stat(filepath)
        candidates = []

        # Prefer birthtime (original creation date, survives copies)
        birth = getattr(stat, 'st_birthtime', None)
        if birth:
            candidates.append(datetime.fromtimestamp(birth))

        # mtime as secondary (unreliable for copied/imported media)
        if hasattr(stat, 'st_mtime'):
            candidates.append(datetime.fromtimestamp(stat.st_mtime))

        # ctime as last resort
        candidates.append(datetime.fromtimestamp(stat.st_ctime))

        # Pick the OLDEST valid date (most likely to be the real capture date)
        # Reject dates in the future
        now = datetime.now()
        valid = [d for d in candidates if d <= now]
        if valid:
            return min(valid)

    except OSError:
        pass
    return datetime.now()


def is_excluded_path(rel_path: str) -> bool:
    """True if rel_path (relative to STORAGE_PATH) is an excluded directory or inside one.
    Whole path components are compared: "Vault/Harsh/Mac/Private" excludes
    ".../Private/x.jpg" but not ".../PrivateTrip/x.jpg"."""
    rel = os.path.normpath(rel_path)
    for ep in NORMALIZED_EXCLUDED_PATHS:
        if rel == ep or rel.startswith(ep + os.sep):
            return True
    return False


def _platform_source(platform: Optional[str], source_id: Optional[str]) -> str:
    """v2 device source -> media_files.source, the same mapping the v2 ingest upsert uses."""
    try:
        from routers.ingest_v2 import v1_source_key
        return v1_source_key(source_id, platform)
    except Exception:
        pass  # standalone use without the API package: equivalent fallback
    p = (platform or "").lower()
    sid = (source_id or "").lower()
    if p in ("ios", "iphone", "ipados"):
        return "iphone"
    if p in ("macos", "darwin", "mac", "osx"):
        return "mac"
    if p == "windows":
        return "windows"
    if "iphone" in sid or "ios" in sid:
        return "iphone"
    if "mac" in sid:
        return "mac"
    if "win" in sid or "laptop" in sid or "pc" in sid:
        return "windows"
    return sid or "unknown"


def derive_source(relative_path: str, db: Optional[Session] = None) -> str:
    """Timeline source for a file, from where it lives under STORAGE_PATH:
      Vault/<Device>/...            e.g. Vault/Windows_laptop-HP/...  (SOURCE_MAPPING)
      Vault/<Owner>/<Device>/...    e.g. Vault/Harsh/Iphone/...       -> "iphone"
      Vault/YYYY/MM/<sha16>_<name>  v2 canonical object -> platform of the uploading device
                                    (looked up in the v2 tables), "unknown" if not registered
    """
    rel = relative_path.replace(os.sep, "/")
    parts = rel.split("/")
    if len(parts) < 3 or parts[0] != "Vault":
        return "unknown"
    if _V2_CANONICAL_RE.match(rel):
        if db is not None:
            try:
                row = db.execute(
                    text("""
                        SELECT s.platform, s.id
                        FROM physical_objects po
                        JOIN logical_items li ON li.physical_object_id = po.id
                        JOIN sources s ON s.id = li.source_id
                        WHERE po.physical_path = :p
                        ORDER BY li.imported_at
                        LIMIT 1
                    """),
                    {"p": relative_path},
                ).first()
                if row:
                    return _platform_source(row[0], row[1])
            except Exception as e:
                logger.debug(f"v2 source lookup failed for {relative_path}: {e}")
        return "unknown"
    if parts[1] in SOURCE_MAPPING:
        return SOURCE_MAPPING[parts[1]]
    if len(parts) >= 4:  # parts[2] is a folder, not the file itself
        return SOURCE_MAPPING.get(parts[2], parts[2].lower())
    return "unknown"


def vault_protection_reason(path: str, db: Optional[Session] = None,
                            st: Optional[os.stat_result] = None) -> Optional[str]:
    """Why v1 tools (trash, maintenance scripts) must not move or delete `path` because it
    belongs to the v2 vault; None for an ordinary file.
    Removing one link of a hardlinked file frees no space, and moving a canonical object
    leaves physical_objects pointing at nothing while clients believe it is stored."""
    if os.path.islink(path):
        return "is a link to another file"
    if st is None:
        st = os.lstat(path)
    if st.st_nlink > 1:
        return "is hardlinked (Synaps vault/mirror copy); deleting one link frees no space"
    rel_path = os.path.relpath(path, STORAGE_PATH)
    if rel_path.split(os.sep)[0] == "Mirrors":
        return "is a Mirrors/ entry managed by the Synaps vault"
    if _V2_OBJECT_NAME_RE.match(rel_path.replace(os.sep, "/")):
        return "is a canonical Synaps vault object"
    if db is not None:
        try:
            registered = db.execute(
                text("SELECT 1 FROM physical_objects WHERE physical_path = :p LIMIT 1"), {"p": rel_path}
            ).first()
        except Exception:
            registered = None  # pre-v2 database without the table
        if registered:
            return "is a canonical Synaps vault object"
    return None


def _storage_is_mounted() -> bool:
    """False if STORAGE_PATH is missing or empty — what an unmounted data disk looks like."""
    try:
        with os.scandir(STORAGE_PATH) as it:
            return any(not entry.name.startswith(".") for entry in it)
    except OSError:
        return False


def _build_media_file(filepath: str, root: str, filename: str, ext: str, db: Session) -> MediaFile:
    file_stat = os.stat(filepath)
    relative_path = os.path.relpath(filepath, STORAGE_PATH)
    # v2 canonical objects are stored as <sha256[:16]>_<name>; index them under <name> like the
    # ingest upsert does (classification looks at the name, e.g. IMG_1234.PNG screenshots)
    if _V2_OBJECT_NAME_RE.match(relative_path.replace(os.sep, "/")):
        filename = filename[17:] or filename
    classification = classify_media(ext, filename)
    date_taken = get_best_date(filepath, filename)
    file_hash = compute_file_hash(filepath)
    mime_type, _ = mimetypes.guess_type(filepath)

    return MediaFile(
        filename=filename,
        path=filepath,
        relative_path=relative_path,
        directory=os.path.relpath(root, STORAGE_PATH),
        source=derive_source(relative_path, db),
        extension=ext,
        mime_type=mime_type or "application/octet-stream",
        file_size=file_stat.st_size,
        media_type=classification["media_type"],
        is_screenshot=classification["is_screenshot"],
        is_screen_recording=classification["is_screen_recording"],
        is_raw=classification["is_raw"],
        date_taken=date_taken,
        date_created=datetime.fromtimestamp(
            getattr(file_stat, 'st_birthtime', file_stat.st_ctime)
        ),
        date_modified=datetime.fromtimestamp(file_stat.st_mtime),
        file_hash=file_hash,
    )


# Columns a forced rescan refreshes on existing rows. source, is_favorite, thumbnails and
# anything set by other writers (e.g. the v2 ingest upsert) are left alone.
_RESCAN_COLUMNS = (
    "filename", "relative_path", "directory", "extension", "mime_type", "file_size",
    "media_type", "is_screenshot", "is_screen_recording", "is_raw",
    "date_taken", "date_created", "date_modified", "file_hash",
)


def _commit_batch(db: Session, batch: list, stats: dict) -> None:
    """Insert a batch; if a row appeared concurrently (unique path), fall back to row by row."""
    try:
        db.add_all(batch)
        db.commit()
        return
    except IntegrityError:
        db.rollback()
    except Exception as e:
        db.rollback()
        stats["errors"] += len(batch)
        stats["new"] -= len(batch)
        logger.error(f"Batch commit failed ({len(batch)} files): {e}")
        return
    for media_file in batch:
        try:
            db.add(media_file)
            db.commit()
        except IntegrityError:
            db.rollback()  # indexed by someone else meanwhile (e.g. the v2 ingest) — keep theirs
            stats["new"] -= 1
            stats["skipped"] += 1
        except Exception as e:
            db.rollback()
            stats["new"] -= 1
            stats["errors"] += 1
            logger.error(f"Error indexing {media_file.path}: {e}")


def _top_folder_available(relative_path: Optional[str], cache: dict) -> bool:
    """False if the row's top-level folder (e.g. Vault/) is gone or empty: a separately
    mounted disk that is offline, not a deleted file."""
    top = (relative_path or "").replace(os.sep, "/").split("/")[0]
    if not top or top in (".", ".."):
        return True
    if top not in cache:
        try:
            with os.scandir(os.path.join(STORAGE_PATH, top)) as it:
                cache[top] = any(True for _ in it)
        except OSError:
            cache[top] = False
    return cache[top]


def _garbage_collect(db: Session, stats: dict, allow_mass_delete: bool) -> None:
    """Drop rows whose file is gone or now lies in an excluded folder — unless the missing
    files look like an unmounted/half-mounted disk rather than deleted files."""
    if not _storage_is_mounted():
        logger.warning(f"Skipping garbage collection: {STORAGE_PATH} is missing or empty (disk not mounted?)")
        stats["gc_skipped"] = "storage_unavailable"
        return

    rows = db.query(MediaFile.id, MediaFile.path, MediaFile.relative_path).all()
    missing, excluded, offline = [], [], 0
    top_folders = {}
    for media_id, path, relative_path in rows:
        if relative_path and is_excluded_path(relative_path):
            excluded.append(media_id)  # config decision, deleted even though the file exists
        elif not os.path.exists(path):
            if _top_folder_available(relative_path, top_folders):
                missing.append(media_id)
            else:
                offline += 1

    if offline:
        logger.warning(f"Keeping {offline} records whose top-level folder is missing or empty (disk offline?)")
    if (missing and not allow_mass_delete and len(rows) >= GC_MIN_ROWS_FOR_GUARD
            and len(missing) > len(rows) * GC_MAX_DELETE_FRACTION):
        logger.warning(
            f"Not deleting {len(missing)} of {len(rows)} records whose files are missing: that looks "
            f"like a storage problem, not deleted files. If it is real, run "
            f"clean_stale_records.py --dry-run, then --execute."
        )
        stats["gc_skipped"] = "too_many_missing"
        missing = []

    stale_ids = missing + excluded
    for i in range(0, len(stale_ids), 500):
        db.query(MediaFile).filter(MediaFile.id.in_(stale_ids[i:i + 500])).delete(synchronize_session=False)
    if stale_ids:
        db.commit()
        logger.info(f"Deleted {len(stale_ids)} stale records from database "
                    f"({len(missing)} missing, {len(excluded)} excluded)")
    stats["stale_deleted"] = len(stale_ids)


def scan_directory(db: Session, force_rescan: bool = False, allow_mass_delete: bool = False) -> dict:
    """
    Scan the whitelisted storage directories and index all media files.
    Only indexes photos and videos (not documents) for the timeline.
    Optimized for low-power NAS with batch processing.
    force_rescan refreshes metadata of already indexed files (keeping their source/favorites).
    """
    stats = {"scanned": 0, "new": 0, "skipped": 0, "errors": 0, "updated": 0}

    # Pre-fetch all existing paths into memory for fast lookups
    existing = {}
    for media_id, path in db.query(MediaFile.id, MediaFile.path):
        existing[path] = media_id
    logger.info(f"Loaded {len(existing)} existing paths from DB")

    # App directories that may sit inside the storage root (dev setups)
    app_dirs = {os.path.abspath(THUMBNAIL_DIR), os.path.abspath(TRASH_DIR)}

    for base_path in ALLOWED_SCAN_PATHS:
        if not os.path.exists(base_path):
            logger.warning(f"Allowed path does not exist: {base_path}")
            continue

        logger.info(f"Scanning: {base_path}")

        for root, dirs, files in os.walk(base_path):
            rel_root = os.path.relpath(root, STORAGE_PATH)
            if rel_root != "." and is_excluded_path(rel_root):
                dirs[:] = []  # Stop recursion
                logger.debug(f"Skipping excluded directory: {rel_root}")
                continue

            # Skip hidden directories (.synaps_tmp, .git, ...), system dirs and excluded
            # folders before descending into them
            dirs[:] = [
                d for d in dirs
                if not d.startswith('.') and d not in _SKIP_DIR_NAMES
                and os.path.abspath(os.path.join(root, d)) not in app_dirs
                and not is_excluded_path(os.path.join(rel_root, d))
            ]

            batch = []

            for filename in files:
                if filename.startswith('.') or filename.lower().endswith('.aae') or filename.lower().endswith('.tmp'):
                    continue

                ext = os.path.splitext(filename)[1].lower()
                # Only index media files (photos + videos) for timeline
                if ext not in ALL_MEDIA_EXTENSIONS:
                    continue

                filepath = os.path.join(root, filename)
                stats["scanned"] += 1

                # Fast memory lookup instead of DB query per file
                existing_id = existing.get(filepath)
                if existing_id is not None and not force_rescan:
                    stats["skipped"] += 1
                    continue

                try:
                    media_file = _build_media_file(filepath, root, filename, ext, db)
                except Exception as e:
                    stats["errors"] += 1
                    logger.error(f"Error scanning {filepath}: {e}")
                    continue

                if existing_id is not None:
                    # Forced rescan of an indexed file: refresh file metadata in place
                    try:
                        db.query(MediaFile).filter(MediaFile.id == existing_id).update(
                            {getattr(MediaFile, c): getattr(media_file, c) for c in _RESCAN_COLUMNS},
                            synchronize_session=False,
                        )
                        stats["updated"] += 1
                        if stats["updated"] % SCAN_BATCH_SIZE == 0:
                            db.commit()
                    except Exception as e:
                        db.rollback()
                        stats["errors"] += 1
                        logger.error(f"Error refreshing {filepath}: {e}")
                    continue

                batch.append(media_file)
                stats["new"] += 1

                # Commit in batches to limit memory usage
                if len(batch) >= SCAN_BATCH_SIZE:
                    _commit_batch(db, batch, stats)
                    logger.info(f"  Committed batch of {len(batch)} files")
                    batch = []

            # Commit remaining batch for this directory
            if batch:
                _commit_batch(db, batch, stats)
                logger.info(f"  Committed final batch of {len(batch)} files from {root}")

    if stats["updated"]:
        try:
            db.commit()
        except Exception as e:
            db.rollback()
            logger.error(f"Committing refreshed records failed: {e}")

    # ── Database Garbage Collection ──
    logger.info("Running database garbage collection...")
    stats["stale_deleted"] = 0
    try:
        _garbage_collect(db, stats, allow_mass_delete)
    except Exception as e:
        db.rollback()
        logger.error(f"Garbage collection failed: {e}")

    logger.info(f"Scan complete: {stats}")
    return stats


def index_single_file(filepath: str, db: Session) -> Optional[MediaFile]:
    """Index a single file and add it to the database. Used for restore-from-trash.
    Returns the created MediaFile or None if it fails."""
    if not os.path.exists(filepath):
        logger.error(f"Cannot index — file not found: {filepath}")
        return None

    filename = os.path.basename(filepath)
    ext = os.path.splitext(filename)[1].lower()

    if ext not in ALL_MEDIA_EXTENSIONS:
        logger.warning(f"Cannot index — unsupported extension: {ext}")
        return None

    # Skip if already indexed
    existing = db.query(MediaFile).filter(MediaFile.path == filepath).first()
    if existing:
        return existing

    try:
        media_file = _build_media_file(filepath, os.path.dirname(filepath), filename, ext, db)
        db.add(media_file)
        db.commit()
        logger.info(f"Re-indexed restored file: {filename}")
        return media_file

    except IntegrityError:
        db.rollback()
        return db.query(MediaFile).filter(MediaFile.path == filepath).first()
    except Exception as e:
        db.rollback()
        logger.error(f"Failed to index restored file {filepath}: {e}")
        return None
