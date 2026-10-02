"""
Synaps Thumbnail Pre-Generation & Heating Engine
Crawls storage directories (prioritizing newest folders first)
and pre-generates lightweight WebP thumbnails ahead of time.

Usage:
  python3 preheat_thumbnails.py                     # Pre-heat all of /storage/Vault (newest first)
  python3 preheat_thumbnails.py --path Vault/2026/09 # Pre-heat a specific folder
  python3 preheat_thumbnails.py --limit 500         # Pre-heat first 500 missing items
"""
import os
import sys
import time
import argparse
import gc
import logging

# Ensure backend root is on sys.path
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, SCRIPT_DIR)

from config import STORAGE_PATH, THUMBNAIL_DIR, IMAGE_EXTENSIONS, VIDEO_EXTENSIONS
from thumbnails import (
    get_thumbnail_path,
    generate_image_thumbnail,
    generate_video_thumbnail,
    ensure_thumbnail_dir,
)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S"
)
logger = logging.getLogger("synaps.preheat")

ALL_MEDIA = IMAGE_EXTENSIONS | VIDEO_EXTENSIONS | {'.heic', '.heif', '.mov', '.mp4', '.m4v', '.jpg', '.jpeg', '.png', '.webp'}


from concurrent.futures import ThreadPoolExecutor, as_completed
import threading

def process_single_file(file_path: str, idx: int, total_candidates: int, db_lock, db_session_factory) -> tuple:
    """Worker function to generate thumbnail for a single file."""
    thumb_path = get_thumbnail_path(file_path)
    if os.path.exists(thumb_path):
        return ("cached", file_path, 0, 0)

    ext = os.path.splitext(file_path)[1].lower()
    rel_name = os.path.relpath(file_path, STORAGE_PATH)
    t0 = time.time()
    success = False

    try:
        if ext in VIDEO_EXTENSIONS or ext in ('.mov', '.mp4', '.m4v'):
            success = generate_video_thumbnail(file_path, thumb_path)
        else:
            success = generate_image_thumbnail(file_path, thumb_path)
    except Exception as e:
        logger.error(f"Thumbnail error on {rel_name}: {e}")
        success = False

    dt = time.time() - t0

    if success and os.path.exists(thumb_path):
        size_kb = os.path.getsize(thumb_path) / 1024.0
        # Optional DB update
        if db_session_factory:
            try:
                with db_lock:
                    db = db_session_factory()
                    from models import MediaFile
                    media = db.query(MediaFile).filter(
                        (MediaFile.path == file_path) | (MediaFile.relative_path == rel_name)
                    ).first()
                    if media:
                        media.has_thumbnail = True
                        media.thumbnail_path = thumb_path
                        db.commit()
                    db.close()
            except Exception:
                pass
        return ("generated", rel_name, size_kb, dt)
    else:
        return ("failed", rel_name, 0, dt)


def preheat_directory(target_rel_path: str = "Vault", limit: int = 0, delay_sec: float = 0.0, workers: int = 2):
    """
    Crawls target path, prioritizing newest subdirectories first,
    and pre-generates missing WebP thumbnails with concurrent workers.
    """
    ensure_thumbnail_dir()
    clean_path = target_rel_path.strip("/")
    full_target = os.path.join(STORAGE_PATH, clean_path) if clean_path else STORAGE_PATH

    if not os.path.exists(full_target):
        print(f"❌ Error: Target path not found: {full_target}")
        return

    print("=" * 65)
    print(" 🔥 Synaps Thumbnail Pre-Generation Engine (High Throughput)")
    print(f" Target path:  {full_target}")
    print(f" Output dir:   {THUMBNAIL_DIR}")
    print(f" Workers:      {workers} parallel threads")
    print(f" Delay:        {delay_sec}s")
    print("=" * 65)

    # 1. Gather all media files
    print("\n🔍 Scanning files to process (sorting newest first)...")
    found_files = []
    
    if os.path.isfile(full_target):
        found_files.append(full_target)
    else:
        for root, dirs, files in os.walk(full_target):
            # Sort subdirectories descending (e.g. 2026 before 2025, 10 before 09)
            dirs.sort(reverse=True)
            for f in sorted(files, reverse=True):
                if f.startswith('.'):
                    continue
                ext = os.path.splitext(f)[1].lower()
                if ext in ALL_MEDIA:
                    found_files.append(os.path.join(root, f))

    total_candidates = len(found_files)
    print(f"✅ Found {total_candidates:,} total media files.")

    already_cached = 0
    generated_count = 0
    failed_count = 0
    start_time = time.time()

    db_session_factory = None
    try:
        from database import SessionLocal
        db_session_factory = SessionLocal
    except Exception:
        pass
    db_lock = threading.Lock()

    # Pre-filter already cached if possible, or stream through executor
    to_process = []
    for fp in found_files:
        if os.path.exists(get_thumbnail_path(fp)):
            already_cached += 1
        else:
            to_process.append(fp)

    print(f"ℹ️  Already cached: {already_cached:,} files.")
    print(f"🚀 Queued for generation: {len(to_process):,} files across {workers} workers.")

    if limit > 0:
        to_process = to_process[:limit]

    try:
        with ThreadPoolExecutor(max_workers=workers) as executor:
            futures = {
                executor.submit(process_single_file, fp, i, total_candidates, db_lock, db_session_factory): fp 
                for i, fp in enumerate(to_process, 1)
            }
            
            for future in as_completed(futures):
                status, rel_name, size_kb, dt = future.result()
                if status == "generated":
                    generated_count += 1
                    print(f"[{already_cached + generated_count:,}/{total_candidates:,}] ✨ {rel_name} ({size_kb:.1f} KB in {dt:.2f}s)")
                elif status == "failed":
                    failed_count += 1
                    print(f"[{already_cached + generated_count:,}/{total_candidates:,}] ⚠️  Failed: {rel_name}")
                elif status == "cached":
                    already_cached += 1

                if (generated_count + already_cached) % 100 == 0:
                    elapsed = time.time() - start_time
                    rate = generated_count / max(elapsed, 1)
                    print(f"   --> Progress: {already_cached + generated_count:,}/{total_candidates:,} | Generated: {generated_count:,} | Rate: {rate:.1f} thumbs/s")
                    gc.collect()

                if delay_sec > 0:
                    time.sleep(delay_sec)

    except KeyboardInterrupt:
        print("\n\n⏹️ Pre-generation paused by user.")

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
    parser.add_argument("--workers", type=int, default=2, help="Number of parallel workers (default: 2)")
    args = parser.parse_args()

    preheat_directory(target_rel_path=args.path, limit=args.limit, delay_sec=args.delay, workers=args.workers)

