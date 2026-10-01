"""
Synaps Thumbnail Generator
Lightweight thumbnail generation with caching.
Supports: JPEG, PNG, WebP, HEIC, MP4/MOV videos, PDFs.
Optimized for Core2Duo NAS.
"""
import os
import subprocess
import logging
from pathlib import Path
from PIL import Image
from config import THUMBNAIL_DIR, THUMBNAIL_SIZE, THUMBNAIL_QUALITY, VIDEO_EXTENSIONS

logger = logging.getLogger("synaps.thumbnails")

# Check for pillow-heif support
try:
    from pillow_heif import register_heif_opener
    register_heif_opener()
    HAS_HEIF = True
    logger.info("HEIC support enabled via pillow-heif")
except ImportError:
    HAS_HEIF = False
    logger.warning("pillow-heif not installed — HEIC thumbnails disabled")

HEIC_EXTENSIONS = {'.heic', '.heif'}
PDF_EXTENSIONS = {'.pdf'}


def ensure_thumbnail_dir():
    """Create thumbnail directory if it doesn't exist."""
    os.makedirs(THUMBNAIL_DIR, exist_ok=True)


def get_thumbnail_path(file_path: str) -> str:
    """Generate a deterministic thumbnail path for a given file."""
    import hashlib
    path_hash = hashlib.md5(file_path.encode()).hexdigest()
    return os.path.join(THUMBNAIL_DIR, f"{path_hash}.webp")


def generate_image_thumbnail(source_path: str, thumb_path: str) -> bool:
    """Generate a thumbnail for an image file (JPEG, PNG, WebP, HEIC).
    Optimized for Core 2 Duo: uses BILINEAR scaling and fast WebP encoding."""
    try:
        with Image.open(source_path) as img:
            # Convert RGBA/P to RGB for WebP compatibility
            if img.mode in ('RGBA', 'LA', 'P'):
                img = img.convert('RGB')

            # Use BILINEAR for fast, low-CPU downscaling on weak hardware
            img.thumbnail(THUMBNAIL_SIZE, Image.BILINEAR)
            img.save(thumb_path, "WEBP", quality=THUMBNAIL_QUALITY, method=0)
            return True
    except Exception as e:
        logger.error(f"Image thumbnail failed: {source_path}: {e}")
        return False


def generate_video_thumbnail(source_path: str, thumb_path: str) -> bool:
    """Generate a thumbnail for a video using ffmpeg.
    Extracts a single frame at 0.5s with -threads 1 to preserve CPU responsiveness."""
    try:
        # Fast input seek with single thread (so the 2nd core remains 100% free for API browsing)
        result = subprocess.run(
            [
                "ffmpeg", "-y",
                "-threads", "1",
                "-ss", "0.5",
                "-noaccurate_seek",
                "-i", source_path,
                "-vframes", "1",
                "-vf", f"scale={THUMBNAIL_SIZE[0]}:-1",
                "-q:v", "5",
                "-loglevel", "error",
                thumb_path
            ],
            capture_output=True,
            timeout=10,
        )

        if result.returncode == 0 and os.path.exists(thumb_path):
            return True

        # Fallback: try first frame (for very short clips)
        result = subprocess.run(
            [
                "ffmpeg", "-y",
                "-threads", "1",
                "-i", source_path,
                "-vframes", "1",
                "-vf", f"scale={THUMBNAIL_SIZE[0]}:-1",
                "-q:v", "5",
                "-loglevel", "error",
                thumb_path
            ],
            capture_output=True,
            timeout=10,
        )
        return result.returncode == 0 and os.path.exists(thumb_path)

    except FileNotFoundError:
        logger.error("ffmpeg not found — install with: sudo apt install ffmpeg")
        return False
    except subprocess.TimeoutExpired:
        logger.error(f"Video thumbnail timed out: {source_path}")
        return False
    except Exception as e:
        logger.error(f"Video thumbnail failed: {source_path}: {e}")
        return False


def generate_pdf_thumbnail(source_path: str, thumb_path: str) -> bool:
    """Generate a thumbnail for a PDF using pdftoppm (poppler-utils).
    Extracts first page only."""
    try:
        # Generate temporary PNG from first page
        temp_path = thumb_path.replace('.webp', '_temp.png')
        result = subprocess.run(
            [
                "pdftoppm", "-png", "-f", "1", "-l", "1",
                "-scale-to", str(THUMBNAIL_SIZE[0]),
                source_path, temp_path.replace('.png', '')
            ],
            capture_output=True,
            timeout=15,
        )

        # pdftoppm adds -01.png suffix
        actual_temp = temp_path.replace('.png', '-01.png')
        if not os.path.exists(actual_temp):
            actual_temp = temp_path.replace('.png', '-1.png')

        if os.path.exists(actual_temp):
            with Image.open(actual_temp) as img:
                img.thumbnail(THUMBNAIL_SIZE, Image.LANCZOS)
                img.save(thumb_path, "WEBP", quality=THUMBNAIL_QUALITY)
            os.remove(actual_temp)
            return True

        return False
    except FileNotFoundError:
        logger.warning("pdftoppm not found — install with: sudo apt install poppler-utils")
        return False
    except Exception as e:
        logger.error(f"PDF thumbnail failed: {source_path}: {e}")
        return False


import queue
import threading

# Setup background worker queue
thumbnail_queue = queue.LifoQueue()
_enqueued_paths = set()
_queue_lock = threading.Lock()

def _thumbnail_worker():
    """Background worker that continuously processes the thumbnail queue with strict memory control."""
    import gc
    while True:
        try:
            item = thumbnail_queue.get()
            if item is None:
                break
            
            source_path, thumb_path = item
            
            if not os.path.exists(thumb_path) and os.path.exists(source_path):
                ext = os.path.splitext(source_path)[1].lower()
                success = False
                if ext in VIDEO_EXTENSIONS:
                    success = generate_video_thumbnail(source_path, thumb_path)
                elif ext in PDF_EXTENSIONS:
                    success = generate_pdf_thumbnail(source_path, thumb_path)
                else:
                    success = generate_image_thumbnail(source_path, thumb_path)
                
                if success:
                    logger.debug(f"Generated thumbnail: {os.path.basename(source_path)}")
                    try:
                        from database import SessionLocal
                        from models import MediaFile
                        from config import STORAGE_PATH
                        with SessionLocal() as db:
                            rel_path = os.path.relpath(source_path, STORAGE_PATH)
                            media = db.query(MediaFile).filter(
                                (MediaFile.path == source_path) | (MediaFile.relative_path == rel_path)
                            ).first()
                            if media:
                                media.has_thumbnail = True
                                media.thumbnail_path = thumb_path
                                db.commit()
                    except Exception as db_e:
                        logger.debug(f"DB update failed: {db_e}")
                gc.collect()
            
            with _queue_lock:
                _enqueued_paths.discard(source_path)
            thumbnail_queue.task_done()
        except Exception as e:
            logger.error(f"Thumbnail worker error: {e}")
            if 'source_path' in locals():
                with _queue_lock:
                    _enqueued_paths.discard(source_path)
            thumbnail_queue.task_done()

# Start 1 dedicated worker thread (optimal for Core2Duo to avoid CPU & RAM thrashing)
worker_thread = threading.Thread(target=_thumbnail_worker, daemon=True)
worker_thread.start()

def enqueue_thumbnail(source_path: str) -> str:
    """Enqueue a thumbnail for background generation and return its expected path."""
    ensure_thumbnail_dir()
    thumb_path = get_thumbnail_path(source_path)
    
    if not os.path.exists(thumb_path):
        with _queue_lock:
            if source_path not in _enqueued_paths:
                _enqueued_paths.add(source_path)
                thumbnail_queue.put((source_path, thumb_path))
        
    return thumb_path

def generate_thumbnail(source_path: str) -> str | None:
    """Legacy synchronous call, kept for backward compatibility if needed."""
    return enqueue_thumbnail(source_path)


def batch_generate_thumbnails(file_paths: list[str], db_session=None) -> dict:
    """Generate thumbnails for a batch of files. Updates DB if session provided."""
    from models import MediaFile

    stats = {"generated": 0, "cached": 0, "failed": 0}

    for path in file_paths:
        thumb_path = get_thumbnail_path(path)

        if os.path.exists(thumb_path):
            stats["cached"] += 1
            continue

        result = generate_thumbnail(path)

        if result:
            stats["generated"] += 1
            if db_session:
                media = db_session.query(MediaFile).filter(MediaFile.path == path).first()
                if media:
                    media.has_thumbnail = True
                    media.thumbnail_path = result
        else:
            stats["failed"] += 1

    if db_session:
        db_session.commit()

    logger.info(f"Batch thumbnails: {stats}")
    return stats
