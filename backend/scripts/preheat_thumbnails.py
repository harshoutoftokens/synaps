"""
Synaps Thumbnail Pre-Generation & Heating Engine
Crawls storage directories (prioritizing newest folders first)
and pre-generates lightweight WebP thumbnails ahead of time.

Runs at low CPU priority with one worker by default: the server's own thumbnail worker
and the web UI keep the other core of the Core 2 Duo. Only the thumbnail cache (and the
media_files has_thumbnail flags) are written; media files are never modified.

Usage:
  python3 scripts/preheat_thumbnails.py                     # Pre-heat all of /storage/Vault (newest first)
  python3 scripts/preheat_thumbnails.py --path Vault/2026/09 # Pre-heat a specific folder
  python3 scripts/preheat_thumbnails.py --limit 500         # Pre-heat first 500 missing items
  python3 scripts/preheat_thumbnails.py --workers 2         # Use both cores (only when the NAS is idle)
"""
import os
import sys
import time
import argparse
import gc
import logging

# Ensure backend root is on sys.path
# Make the backend modules (config, thumbnails, ...) importable however this script is started
BACKEND_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, BACKEND_DIR)

from config import STORAGE_PATH, THUMBNAIL_DIR, IMAGE_EXTENSIONS, VIDEO_EXTENSIONS
from thumbnails import (
    get_thumbnail_path,
    find_fresh_thumbnail,
    generate_thumbnail_file,
    ensure_thumbnail_dir,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("synaps.preheat")

ALL_MEDIA = IMAGE_EXTENSIONS | VIDEO_EXTENSIONS | {'.heic', '.heif', '.mov', '.mp4', '.m4v', '.jpg', '.jpeg', '.png', '.webp'}


from concurrent.futures import ThreadPoolExecutor, FIRST_COMPLETED, wait


def process_single_file(file_path: str) -> tuple:
    """Worker function to generate thumbnail for a single file."""
    thumb_path = get_thumbnail_path(file_path)
    rel_name = os.path.relpath(file_path, STORAGE_PATH)
    try:
        source_stat = os.stat(file_path)
    except OSError:
        return ("failed", rel_name, 0, 0, file_path, thumb_path)
    if find_fresh_thumbnail(thumb_path, source_stat) is not None:
        return ("cached", rel_name, 0, 0, file_path, thumb_path)

    t0 = time.time()
    try:
        success = generate_thumbnail_file(file_path, thumb_path)
    except Exception as e:  # never let one bad file stop the run
        logger.error(f"Thumbnail error on {rel_name}: {e}")
        success = False
    dt = time.time() - t0

    if success and os.path.exists(thumb_path):
        size_kb = os.path.getsize(thumb_path) / 1024.0
        return ("generated", rel_name, size_kb, dt, file_path, thumb_path)
    return ("failed", rel_name, 0, dt, file_path, thumb_path)


def resolve_target(target_rel_path: str):
    """Absolute path for --path, confined to the storage root (None if it escapes)."""
    clean_path = target_rel_path.strip("/")
    full_target = os.path.join(STORAGE_PATH, clean_path) if clean_path else STORAGE_PATH
    root_real = os.path.realpath(STORAGE_PATH)
    real_target = os.path.realpath(full_target)
    if os.path.commonpath([real_target, root_real]) != root_real:
        return None
    return full_target


def collect_media(full_target: str) -> list:
    """Media files under full_target, newest folders first, skipping hidden folders."""
    if os.path.isfile(full_target):
        return [full_target]
    found_files = []
    for root, dirs, files in os.walk(full_target):
        # Sort subdirectories descending (e.g. 2026 before 2025, 10 before 09)
        dirs[:] = sorted((d for d in dirs if not d.startswith('.')), reverse=True)
        for f in sorted(files, reverse=True):
            if f.startswith('.'):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext in ALL_MEDIA:
                found_files.append(os.path.join(root, f))
    return found_files


def _flush_db(updates: list) -> None:
    """Mark generated thumbnails in media_files (one short transaction per batch)."""
    if not updates:
        return
    try:
        from database import SessionLocal
        from models import MediaFile
        with SessionLocal() as db:
            for file_path, thumb_path in updates:
                db.query(MediaFile).filter(MediaFile.path == file_path).update(
                    {MediaFile.has_thumbnail: True, MediaFile.thumbnail_path: thumb_path},
                    synchronize_session=False,
                )
            db.commit()
    except Exception as e:
        logger.debug(f"DB update skipped: {e}")


def preheat_directory(target_rel_path: str = "Vault", limit: int = 0, delay_sec: float = 0.0, workers: int = 1):
    """
    Crawls target path, prioritizing newest subdirectories first,
    and pre-generates missing (or outdated) WebP thumbnails with a small worker pool.
    """
    ensure_thumbnail_dir()
    full_target = resolve_target(target_rel_path)
    if full_target is None:
        print(f"❌ Error: --path must stay inside the storage root ({STORAGE_PATH})")
        return
    if not os.path.exists(full_target):
        print(f"❌ Error: Target path not found: {full_target}")
        return

    workers = max(1, workers)

    print("=" * 65)
    print(" 🔥 Synaps Thumbnail Pre-Generation Engine")
    print(f" Target path:  {full_target}")
    print(f" Output dir:   {THUMBNAIL_DIR}")
    print(f" Workers:      {workers} parallel threads (low priority)")
    print(f" Delay:        {delay_sec}s")
    print("=" * 65)

    # 1. Gather all media files
    print("\n🔍 Scanning files to process (sorting newest first)...")
    found_files = collect_media(full_target)
    total_candidates = len(found_files)
    print(f"✅ Found {total_candidates:,} total media files.")

    already_cached = 0
    generated_count = 0
    failed_count = 0
    start_time = time.time()

    # Pre-filter files whose thumbnail is present and newer than the file
    to_process = []
    for fp in found_files:
        try:
            fresh = find_fresh_thumbnail(get_thumbnail_path(fp), os.stat(fp)) is not None
        except OSError:
            fresh = False
        if fresh:
            already_cached += 1
        else:
            to_process.append(fp)
    del found_files

    print(f"ℹ️  Already cached: {already_cached:,} files.")
    if limit > 0:
        to_process = to_process[:limit]
    print(f"🚀 Queued for generation: {len(to_process):,} files across {workers} workers.")

    db_updates = []
    executor = ThreadPoolExecutor(max_workers=workers)
    in_flight = set()
    pending = iter(to_process)
    try:
        while True:
            # Keep only a small window submitted: 100k futures up front would cost ~100 MB
            # and make Ctrl+C wait for all of them.
            while len(in_flight) < workers * 2:
                fp = next(pending, None)
                if fp is None:
                    break
                in_flight.add(executor.submit(process_single_file, fp))
            if not in_flight:
                break
            done, in_flight = wait(in_flight, return_when=FIRST_COMPLETED)
            for future in done:
                status, rel_name, size_kb, dt, file_path, thumb_path = future.result()
                if status == "generated":
                    generated_count += 1
                    db_updates.append((file_path, thumb_path))
                    print(f"[{already_cached + generated_count:,}/{total_candidates:,}] ✨ {rel_name} ({size_kb:.1f} KB in {dt:.2f}s)")
                elif status == "failed":
                    failed_count += 1
                    print(f"[{already_cached + generated_count:,}/{total_candidates:,}] ⚠️  Failed: {rel_name}")
                elif status == "cached":
                    already_cached += 1

                if generated_count and generated_count % 100 == 0 and status == "generated":
                    elapsed = time.time() - start_time
                    rate = generated_count / max(elapsed, 1)
                    print(f"   --> Progress: {already_cached + generated_count:,}/{total_candidates:,} | Generated: {generated_count:,} | Rate: {rate:.1f} thumbs/s")
                    _flush_db(db_updates)
                    db_updates = []
                    gc.collect()

                if delay_sec > 0:
                    time.sleep(delay_sec)

    except KeyboardInterrupt:
        print("\n\n⏹️ Pre-generation paused by user.")
        executor.shutdown(wait=True, cancel_futures=True)
    else:
        executor.shutdown(wait=True)
    _flush_db(db_updates)

    total_time = time.time() - start_time
    print("\n" + "=" * 65)
    print(" 🏁 PRE-GENERATION COMPLETE")
    print(f" Total files scanned:     {total_candidates:,}")
    print(f" Already had thumbnails:  {already_cached:,}")
    print(f" Newly generated:         {generated_count:,}")
    print(f" Failed:                  {failed_count:,}")
    print(f" Total time:              {total_time:.1f}s")
    if generated_count > 0:
        print(f" Average speed:           {total_time/generated_count:.2f}s per generated thumbnail")
    print("=" * 65)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Synaps Thumbnail Pre-Generation Engine")
    parser.add_argument("--path", default="Vault", help="Relative path under storage to preheat (default: Vault)")
    parser.add_argument("--limit", type=int, default=0, help="Maximum number of thumbnails to generate (0 = unlimited)")
    parser.add_argument("--delay", type=float, default=0.0, help="Delay between items in seconds (default: 0.0)")
    parser.add_argument("--workers", type=int, default=1, help="Number of parallel workers (default: 1; the NAS has 2 cores)")
    args = parser.parse_args()

    try:
        os.nice(10)  # yield the CPU to the web server and its own thumbnail worker
    except (AttributeError, OSError):
        pass
    preheat_directory(target_rel_path=args.path, limit=args.limit, delay_sec=args.delay, workers=args.workers)
