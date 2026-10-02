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


def preheat_directory(target_rel_path: str = "Vault", limit: int = 0, delay_sec: float = 0.02):
    """
    Crawls target path, prioritizing newest subdirectories first,
    and pre-generates missing WebP thumbnails.
    """
    ensure_thumbnail_dir()
    clean_path = target_rel_path.strip("/")
    full_target = os.path.join(STORAGE_PATH, clean_path) if clean_path else STORAGE_PATH

    if not os.path.exists(full_target):
        print(f"❌ Error: Target path not found: {full_target}")
        return

    print("=" * 65)
    print(" 🔥 Synaps Thumbnail Pre-Generation Engine")
    print(f" Target path:  {full_target}")
    print(f" Output dir:   {THUMBNAIL_DIR}")
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

    # 2. Process each file
    already_cached = 0
    generated_count = 0
    failed_count = 0
    start_time = time.time()

    # Optional DB connection for syncing
    db = None
    try:
        from database import SessionLocal
        db = SessionLocal()
    except Exception:
        pass

    try:
        for idx, file_path in enumerate(found_files, 1):
            if limit > 0 and generated_count >= limit:
                print(f"\nReached limit of {limit} generated thumbnails. Stopping.")
                break

            thumb_path = get_thumbnail_path(file_path)

            if os.path.exists(thumb_path):
                already_cached += 1
                continue

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
                generated_count += 1
                print(f"[{idx:,}/{total_candidates:,}] ✨ {rel_name} ({size_kb:.1f} KB in {dt:.2f}s)")

                # Sync to SQLite if DB available
                if db:
                    try:
                        from models import MediaFile
                        media = db.query(MediaFile).filter(
                            (MediaFile.path == file_path) | (MediaFile.relative_path == rel_name)
                        ).first()
                        if media:
                            media.has_thumbnail = True
                            media.thumbnail_path = thumb_path
                            db.commit()
                    except Exception:
                        pass
            else:
                failed_count += 1
                print(f"[{idx:,}/{total_candidates:,}] ⚠️  Failed: {rel_name}")

            gc.collect()
            if delay_sec > 0:
                time.sleep(delay_sec)

            # Periodic status
            if idx % 100 == 0:
                elapsed = time.time() - start_time
                print(f"   --> Progress: {idx:,}/{total_candidates:,} | Cached: {already_cached:,} | Generated: {generated_count:,} | Rate: {idx/max(elapsed, 1):.1f} items/s")

    except KeyboardInterrupt:
        print("\n\n⏹️ Pre-generation paused by user.")
    finally:
        if db:
            db.close()

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
    parser.add_argument("--delay", type=float, default=0.02, help="Polite delay between items in seconds (default: 0.02)")
    args = parser.parse_args()

    preheat_directory(target_rel_path=args.path, limit=args.limit, delay_sec=args.delay)
