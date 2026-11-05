"""
Synaps Thumbnail Generator
Lightweight thumbnail generation with caching.
Supports: JPEG, PNG, WebP, HEIC, MP4/MOV videos, PDFs.
Optimized for Core2Duo NAS:
  - decode-time downscaling (JPEG DCT scaling, embedded HEIC thumbnails where pillow-heif supports it)
  - one low-priority background worker by default (SYNAPS_THUMBNAIL_WORKERS)
  - bounded LIFO queue with in-flight de-duplication (SYNAPS_THUMBNAIL_QUEUE_MAX)
  - atomic writes, so a crash never leaves a truncated .webp that is served forever
  - failed files are remembered, so clients polling a broken file don't re-run the decoder
"""
import io
import os
import sys
import gc
import time
import shutil
import hashlib
import logging
import subprocess
import threading
from collections import OrderedDict, deque
from typing import Optional

from PIL import Image, ImageOps
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
VIDEO_THUMB_EXTENSIONS = set(VIDEO_EXTENSIONS) | {'.mp4', '.mov', '.m4v'}


def _env_int(name: str, default: int, minimum: int) -> int:
    try:
        return max(minimum, int(os.getenv(name, default)))
    except ValueError:
        logger.warning(f"Ignoring invalid {name}={os.getenv(name)!r}; using {default}")
        return default


# One worker leaves the second core of the Core 2 Duo to the web server and SQLite.
THUMBNAIL_WORKERS = _env_int("SYNAPS_THUMBNAIL_WORKERS", 1, 1)
# Oldest requests are dropped beyond this (they are re-queued if a client asks again).
THUMBNAIL_QUEUE_MAX = _env_int("SYNAPS_THUMBNAIL_QUEUE_MAX", 2000, 1)
FFMPEG_TIMEOUT = 25  # seconds; a stuck decode must not stall the queue
FAILED_RETRY_SECONDS = 6 * 3600  # how long a file that failed is answered with "failed"
_FAILED_MAX_ENTRIES = 10000

# Full-size JPEG renditions of images browsers can't display (HEIC), cached on disk.
PREVIEW_DIR = os.path.join(THUMBNAIL_DIR, "previews")
PREVIEW_MAX_SIZE = (2560, 2560)
PREVIEW_QUALITY = 85
PREVIEW_CACHE_MAX_BYTES = _env_int("SYNAPS_PREVIEW_CACHE_MB", 1024, 16) * 1024 * 1024
PREVIEW_WAIT_SECONDS = 30.0  # a request waits this long for the (single) converter


def ensure_thumbnail_dir():
    """Create thumbnail directory if it doesn't exist."""
    os.makedirs(THUMBNAIL_DIR, exist_ok=True)


def get_thumbnail_path(file_path: str) -> str:
    """Generate a deterministic thumbnail path for a given file.
    The key is the md5 of the path string, so existing caches stay valid."""
    path_hash = hashlib.md5(file_path.encode("utf-8", "surrogateescape")).hexdigest()
    return os.path.join(THUMBNAIL_DIR, f"{path_hash}.webp")


def _atomic_write(dest_path: str, write) -> None:
    """Call write(tmp_path) on a hidden temp file next to dest_path, then rename it into place."""
    directory = os.path.dirname(dest_path) or "."
    tmp_path = os.path.join(
        directory, f".{os.path.basename(dest_path)}.{os.getpid()}.{threading.get_ident()}.tmp"
    )
    try:
        write(tmp_path)
        os.replace(tmp_path, dest_path)
    finally:
        try:
            os.remove(tmp_path)
        except OSError:
            pass


def _fit_within(size: tuple, box: tuple) -> tuple:
    """Size of `size` scaled down (never up) to fit inside `box`, keeping the aspect ratio."""
    width, height = size
    if width <= box[0] and height <= box[1]:
        return width, height
    scale = min(box[0] / width, box[1] / height)
    return max(1, int(width * scale)), max(1, int(height * scale))


def _render(img: Image.Image, box: tuple, resample) -> Image.Image:
    """Downscale an opened (not yet decoded) image to fit `box`, honouring EXIF orientation."""
    try:
        # JPEG: decode straight at 1/2..1/8 scale in the DCT domain (4-8x less work).
        # pillow-heif (newer releases): decode an embedded thumbnail instead of the full
        # HEVC image when it is at least as large as the output.
        img.draft("RGB", _fit_within(img.size, box))
    except Exception:
        pass
    if img.mode in ("P", "PA"):
        img = img.convert("RGBA")  # palette images would otherwise be resized with NEAREST
    elif img.mode not in ("RGB", "RGBA", "L", "LA"):
        img = img.convert("RGB")  # CMYK, YCbCr, 16-bit, ...
    img.thumbnail(box, resample, reducing_gap=2.0)
    # Phones store portrait JPEGs sideways + an Orientation tag. pillow-heif already applies
    # the HEIC rotation and resets the tag to 1, so HEICs are not rotated twice.
    if img.getexif().get(0x0112, 1) not in (None, 1):
        img = ImageOps.exif_transpose(img)
    if img.mode != "RGB":
        img = img.convert("RGB")
    return img


def _save_webp(img: Image.Image, thumb_path: str) -> None:
    _atomic_write(thumb_path, lambda tmp: img.save(tmp, "WEBP", quality=THUMBNAIL_QUALITY, method=0))


_missing_tools_logged = set()


def _which(tool: str) -> Optional[str]:
    path = shutil.which(tool)
    if path is None and tool not in _missing_tools_logged:
        _missing_tools_logged.add(tool)
        package = "poppler-utils" if tool == "pdftoppm" else tool
        logger.error(f"{tool} not found — install with: sudo apt install {package}")
    return path


_low_priority_prefix_cache = None


def _low_priority_prefix() -> list:
    """`nice` (+ `ionice` on Linux) prefix so decoders yield CPU and disk to web requests."""
    global _low_priority_prefix_cache
    if _low_priority_prefix_cache is None:
        prefix = []
        if shutil.which("nice"):
            prefix += ["nice", "-n", "10"]
        if sys.platform.startswith("linux") and shutil.which("ionice"):
            prefix += ["ionice", "-c", "2", "-n", "7"]
        _low_priority_prefix_cache = prefix
    return _low_priority_prefix_cache


def generate_image_thumbnail(source_path: str, thumb_path: str) -> bool:
    """Generate a thumbnail for an image file (JPEG, PNG, WebP, HEIC).
    Optimized for Core 2 Duo: decode-time downscaling, BILINEAR scaling and fast WebP encoding."""
    try:
        with Image.open(source_path) as img:
            _save_webp(_render(img, THUMBNAIL_SIZE, Image.BILINEAR), thumb_path)
        return True
    except Exception as e:
        logger.error(f"Image thumbnail failed: {source_path}: {e}")
        return False


def _grab_video_frame(ffmpeg: str, source_path: str, seek: Optional[str]) -> Optional[bytes]:
    """One scaled frame as PPM bytes (ffmpeg writes to a pipe; Pillow does the WebP encode)."""
    cmd = _low_priority_prefix() + [ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin", "-threads", "1"]
    if seek is not None:
        # Input seek to the nearest keyframe and decode keyframes only: no frames are decoded
        # just to be thrown away, which matters for 4K HEVC on a Core 2 Duo.
        cmd += ["-skip_frame", "nokey", "-ss", seek, "-noaccurate_seek"]
    cmd += [
        "-i", source_path,
        "-map", "0:v:0", "-an", "-sn", "-dn",
        "-frames:v", "1",
        "-vf", f"scale={THUMBNAIL_SIZE[0]}:{THUMBNAIL_SIZE[1]}:force_original_aspect_ratio=decrease",
        "-f", "image2pipe", "-c:v", "ppm", "pipe:1",
    ]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=FFMPEG_TIMEOUT)
    if result.returncode != 0 or not result.stdout:
        return None
    return result.stdout


def generate_video_thumbnail(source_path: str, thumb_path: str) -> bool:
    """Generate a thumbnail for a video using ffmpeg.
    Grabs the keyframe nearest 1s (falls back to the first frame) with -threads 1 at low
    priority to preserve CPU responsiveness."""
    ffmpeg = _which("ffmpeg")
    if not ffmpeg:
        return False
    try:
        for seek in ("1", None):
            frame = _grab_video_frame(ffmpeg, source_path, seek)
            if frame:
                with Image.open(io.BytesIO(frame)) as img:
                    _save_webp(_render(img, THUMBNAIL_SIZE, Image.BILINEAR), thumb_path)
                return True
        logger.error(f"Video thumbnail failed (no frame decoded): {source_path}")
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
    pdftoppm = _which("pdftoppm")
    if not pdftoppm:
        return False
    out_root = os.path.join(
        os.path.dirname(thumb_path) or ".", f".pdf-{os.getpid()}-{threading.get_ident()}"
    )
    png_path = out_root + ".png"
    try:
        result = subprocess.run(
            _low_priority_prefix() + [
                pdftoppm, "-png", "-f", "1", "-l", "1", "-singlefile",
                "-scale-to", str(max(THUMBNAIL_SIZE)),
                source_path, out_root,
            ],
            capture_output=True,
            timeout=15,
        )
        if result.returncode != 0 or not os.path.exists(png_path):
            return False
        with Image.open(png_path) as img:
            _save_webp(_render(img, THUMBNAIL_SIZE, Image.BILINEAR), thumb_path)
        return True
    except subprocess.TimeoutExpired:
        logger.error(f"PDF thumbnail timed out: {source_path}")
        return False
    except Exception as e:
        logger.error(f"PDF thumbnail failed: {source_path}: {e}")
        return False
    finally:
        try:
            os.remove(png_path)
        except OSError:
            pass


def generate_thumbnail_file(source_path: str, thumb_path: str) -> bool:
    """Generate thumb_path from source_path with the generator matching its extension."""
    ext = os.path.splitext(source_path)[1].lower()
    if ext in VIDEO_THUMB_EXTENSIONS:
        return generate_video_thumbnail(source_path, thumb_path)
    if ext in PDF_EXTENSIONS:
        return generate_pdf_thumbnail(source_path, thumb_path)
    return generate_image_thumbnail(source_path, thumb_path)


# ── Cache state helpers (used by the HTTP routers) ────────────────────────

def thumbnail_is_fresh(thumb_stat: os.stat_result, source_stat: Optional[os.stat_result] = None) -> bool:
    """A cached thumbnail is usable unless it is empty or older than its source file."""
    if thumb_stat.st_size == 0:
        return False
    if source_stat is None:
        return True
    source_mtime = source_stat.st_mtime
    if source_mtime > time.time() + 60:
        return True  # future-dated file (bad camera clock): don't regenerate on every request
    return thumb_stat.st_mtime + 1 >= source_mtime


def find_fresh_thumbnail(thumb_path: str, source_stat: Optional[os.stat_result] = None) -> Optional[os.stat_result]:
    """stat() of thumb_path if it exists and is fresh, else None."""
    try:
        thumb_stat = os.stat(thumb_path)
    except OSError:
        return None
    return thumb_stat if thumbnail_is_fresh(thumb_stat, source_stat) else None


_failed = OrderedDict()  # source path -> ((mtime_ns, size) | None, failed_at monotonic)
_failed_lock = threading.Lock()


def _signature(source_stat: Optional[os.stat_result]):
    return (source_stat.st_mtime_ns, source_stat.st_size) if source_stat else None


def _record_failure(source_path: str) -> None:
    try:
        sig = _signature(os.stat(source_path))
    except OSError:
        sig = None
    with _failed_lock:
        _failed[source_path] = (sig, time.monotonic())
        _failed.move_to_end(source_path)
        while len(_failed) > _FAILED_MAX_ENTRIES:
            _failed.popitem(last=False)


def _clear_failure(source_path: str) -> None:
    with _failed_lock:
        _failed.pop(source_path, None)


def thumbnail_failed(source_path: str, source_stat: Optional[os.stat_result] = None) -> bool:
    """True if generating this file's thumbnail failed recently and the file hasn't changed since."""
    with _failed_lock:
        entry = _failed.get(source_path)
    if entry is None:
        return False
    sig, failed_at = entry
    if source_stat is None:
        try:
            source_stat = os.stat(source_path)
        except OSError:
            source_stat = None
    if sig != _signature(source_stat) or time.monotonic() - failed_at > FAILED_RETRY_SECONDS:
        _clear_failure(source_path)
        return False
    return True


def link_thumbnail(existing_thumb: str, thumb_path: str) -> bool:
    """Make thumb_path serve the same image as existing_thumb (hardlink, copy as fallback).
    Used so Mirrors/ paths reuse the canonical Vault thumbnail without regenerating it."""
    try:
        def _write(tmp):
            try:
                os.link(existing_thumb, tmp)
            except OSError:
                shutil.copyfile(existing_thumb, tmp)
        _atomic_write(thumb_path, _write)
        return True
    except OSError as e:
        logger.debug(f"Could not alias thumbnail {existing_thumb} -> {thumb_path}: {e}")
        return False


def move_thumbnail(old_source_path: str, new_source_path: str) -> bool:
    """Carry a cached thumbnail over when a maintenance script moves its source file."""
    old_thumb = get_thumbnail_path(old_source_path)
    try:
        os.replace(old_thumb, get_thumbnail_path(new_source_path))
        return True
    except OSError:
        return False


# ── Background worker ─────────────────────────────────────────────────────

class _ThumbnailQueue:
    """Bounded LIFO queue with in-flight de-duplication.
    Newest requests are served first (what the user is looking at right now); when full,
    the oldest request is dropped — a client that still wants it will ask again."""

    def __init__(self, maxsize: int):
        self._items = deque()
        self._pending = set()  # source paths queued or being generated
        self._cond = threading.Condition()
        self._maxsize = maxsize

    def put(self, source_path: str, thumb_path: str) -> bool:
        with self._cond:
            if source_path in self._pending:
                return False
            if len(self._items) >= self._maxsize:
                dropped_source, _ = self._items.popleft()
                self._pending.discard(dropped_source)
            self._items.append((source_path, thumb_path))
            self._pending.add(source_path)
            self._cond.notify()
            return True

    def get(self) -> tuple:
        with self._cond:
            while not self._items:
                self._cond.wait()
            return self._items.pop()

    def done(self, source_path: str) -> None:
        with self._cond:
            self._pending.discard(source_path)

    def is_pending(self, source_path: str) -> bool:
        with self._cond:
            return source_path in self._pending

    def qsize(self) -> int:
        with self._cond:
            return len(self._items)


_queue = _ThumbnailQueue(THUMBNAIL_QUEUE_MAX)
_workers_started = False
_workers_lock = threading.Lock()


def lower_thread_priority() -> None:
    """Linux nice values are per thread: let request threads preempt the decoder."""
    if not sys.platform.startswith("linux") or not hasattr(os, "setpriority"):
        return
    try:
        tid = threading.get_native_id()
        os.setpriority(os.PRIO_PROCESS, tid, min(19, os.getpriority(os.PRIO_PROCESS, tid) + 10))
    except OSError:
        pass


def _cleanup_stale_temp_files(max_age: float = 600.0) -> None:
    """Remove temp files left behind by a crash mid-write (they never match a real thumbnail)."""
    now = time.time()
    for directory in (THUMBNAIL_DIR, PREVIEW_DIR):
        try:
            with os.scandir(directory) as it:
                for entry in it:
                    if entry.name.startswith(".") and entry.name.endswith(".tmp"):
                        try:
                            if now - entry.stat().st_mtime > max_age:
                                os.remove(entry.path)
                        except OSError:
                            pass
        except OSError:
            pass


def _flush_db_updates(items: list) -> None:
    """Mark generated thumbnails in media_files (indexed by path; one transaction per batch)."""
    try:
        from database import SessionLocal
        from models import MediaFile
        with SessionLocal() as db:
            for source_path, thumb_path in items:
                db.query(MediaFile).filter(MediaFile.path == source_path).update(
                    {MediaFile.has_thumbnail: True, MediaFile.thumbnail_path: thumb_path},
                    synchronize_session=False,
                )
            db.commit()
    except Exception as db_e:
        logger.debug(f"DB update failed: {db_e}")


def _process(source_path: str, thumb_path: str) -> bool:
    """Generate one queued thumbnail. Returns True if a new file was written."""
    try:
        source_stat = os.stat(source_path)
    except OSError:
        return False  # source vanished (trashed/moved) since it was queued
    if find_fresh_thumbnail(thumb_path, source_stat) is not None:
        return False  # generated meanwhile (e.g. by scripts/preheat_thumbnails.py)
    ensure_thumbnail_dir()
    if generate_thumbnail_file(source_path, thumb_path):
        _clear_failure(source_path)
        logger.debug(f"Generated thumbnail: {os.path.basename(source_path)}")
        return True
    _record_failure(source_path)
    return False


def _thumbnail_worker(cleanup: bool):
    """Background worker that continuously processes the thumbnail queue with strict memory control."""
    lower_thread_priority()
    if cleanup:
        _cleanup_stale_temp_files()
    pending_db = []
    last_flush = time.monotonic()
    processed = 0
    while True:
        source_path, thumb_path = _queue.get()
        try:
            if _process(source_path, thumb_path):
                pending_db.append((source_path, thumb_path))
        except Exception as e:  # never let one bad file kill the worker
            logger.error(f"Thumbnail worker error on {source_path}: {e}")
            _record_failure(source_path)
        finally:
            _queue.done(source_path)
        try:
            processed += 1
            if pending_db and (len(pending_db) >= 25 or _queue.qsize() == 0
                               or time.monotonic() - last_flush > 5):
                _flush_db_updates(pending_db)
                pending_db = []
                last_flush = time.monotonic()
            if processed % 50 == 0:
                gc.collect()
        except Exception as e:
            logger.error(f"Thumbnail worker bookkeeping error: {e}")


def _ensure_workers() -> None:
    """Start the worker thread(s) on first use (not at import, so scripts/tests stay quiet)."""
    global _workers_started
    if _workers_started:
        return
    with _workers_lock:
        if _workers_started:
            return
        for i in range(THUMBNAIL_WORKERS):
            threading.Thread(
                target=_thumbnail_worker, args=(i == 0,), name=f"synaps-thumbnail-{i}", daemon=True
            ).start()
        _workers_started = True


def is_thumbnail_pending(source_path: str) -> bool:
    """True while source_path is queued or being generated."""
    return _queue.is_pending(source_path)


def schedule_thumbnail(source_path: str, thumb_path: Optional[str] = None) -> bool:
    """Queue background generation (no-op if already queued). Never blocks."""
    _ensure_workers()
    return _queue.put(source_path, thumb_path or get_thumbnail_path(source_path))


def enqueue_thumbnail(source_path: str) -> str:
    """Enqueue a thumbnail for background generation and return its expected path."""
    ensure_thumbnail_dir()
    thumb_path = get_thumbnail_path(source_path)
    try:
        source_stat = os.stat(source_path)
    except OSError:
        return thumb_path  # nothing to generate from
    if find_fresh_thumbnail(thumb_path, source_stat) is None and not thumbnail_failed(source_path, source_stat):
        schedule_thumbnail(source_path, thumb_path)
    return thumb_path


def generate_thumbnail(source_path: str) -> str | None:
    """Legacy synchronous call, kept for backward compatibility if needed."""
    return enqueue_thumbnail(source_path)


def batch_generate_thumbnails(file_paths: list[str], db_session=None) -> dict:
    """Queue thumbnails for a batch of files (the worker marks media_files rows as it goes).
    `db_session` is accepted for backward compatibility and not used."""
    stats = {"generated": 0, "cached": 0, "failed": 0, "queued": 0}

    for path in file_paths:
        if find_fresh_thumbnail(get_thumbnail_path(path)) is not None:
            stats["cached"] += 1
        elif not os.path.exists(path):
            stats["failed"] += 1
        else:
            enqueue_thumbnail(path)
            stats["queued"] += 1

    logger.info(f"Batch thumbnails: {stats}")
    return stats


# ── Full-size previews (HEIC → JPEG) ──────────────────────────────────────

class PreviewBusy(Exception):
    """The preview converter stayed busy longer than PREVIEW_WAIT_SECONDS (answer 503)."""


# One conversion at a time: a 48 MP HEIC needs ~300 MB while decoding, the NAS has 2 GB.
_preview_semaphore = threading.BoundedSemaphore(1)
_preview_writes = 0


def get_preview_path(source_path: str, source_stat: os.stat_result) -> str:
    """Cache file for a source's preview; the key changes when the source file changes."""
    key = f"{source_path}\0{source_stat.st_mtime_ns}\0{source_stat.st_size}\0{PREVIEW_MAX_SIZE[0]}\0{PREVIEW_QUALITY}"
    digest = hashlib.sha1(key.encode("utf-8", "surrogateescape")).hexdigest()
    return os.path.join(PREVIEW_DIR, f"{digest}.jpg")


def _touch(path: str, path_stat: os.stat_result) -> None:
    # LRU bookkeeping for eviction; at most one metadata write per file per day.
    if time.time() - path_stat.st_mtime > 86400:
        try:
            os.utime(path)
        except OSError:
            pass


def _evict_previews() -> None:
    """Delete least-recently-used previews until the cache is under 90% of its cap."""
    entries, total = [], 0
    try:
        with os.scandir(PREVIEW_DIR) as it:
            for entry in it:
                if entry.name.endswith(".jpg"):
                    try:
                        st = entry.stat()
                    except OSError:
                        continue
                    entries.append((st.st_mtime, st.st_size, entry.path))
                    total += st.st_size
    except OSError:
        return
    if total <= PREVIEW_CACHE_MAX_BYTES:
        return
    entries.sort()
    for _mtime, size, path in entries:
        if total <= PREVIEW_CACHE_MAX_BYTES * 0.9:
            break
        try:
            os.remove(path)
            total -= size
        except OSError:
            pass


def ensure_preview(source_path: str, source_stat: Optional[os.stat_result] = None) -> str:
    """Path of a cached JPEG rendition (max 2560 px) of `source_path`, created on first use.
    Raises PreviewBusy if the converter stays busy, or the decoder's error."""
    global _preview_writes
    if source_stat is None:
        source_stat = os.stat(source_path)
    preview_path = get_preview_path(source_path, source_stat)
    cached = find_fresh_thumbnail(preview_path)
    if cached is not None:
        _touch(preview_path, cached)
        return preview_path

    if not _preview_semaphore.acquire(timeout=PREVIEW_WAIT_SECONDS):
        raise PreviewBusy(source_path)
    try:
        if find_fresh_thumbnail(preview_path) is not None:
            return preview_path  # a concurrent request for the same file produced it while we waited
        os.makedirs(PREVIEW_DIR, exist_ok=True)
        with Image.open(source_path) as img:
            icc_profile = img.info.get("icc_profile")  # iPhone HEICs are Display P3
            preview = _render(img, PREVIEW_MAX_SIZE, Image.LANCZOS)
            save_kwargs = {"quality": PREVIEW_QUALITY}
            if icc_profile:
                save_kwargs["icc_profile"] = icc_profile
            _atomic_write(preview_path, lambda tmp: preview.save(tmp, "JPEG", **save_kwargs))
        _preview_writes += 1
        if _preview_writes % 20 == 1:
            _evict_previews()
        return preview_path
    finally:
        _preview_semaphore.release()
