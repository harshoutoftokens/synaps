#!/usr/bin/env python3
"""
Synaps Media Organizer — Safe NAS Migration Script
===================================================
Reorganizes flat iPhone media into year/month folders:
    /storage/Vault/Harsh/Iphone/IMG_3130.HEIC
    →  /storage/Vault/Harsh/Iphone/2025/05/IMG_3130.HEIC

IMPORTANT:
    This script reuses the EXACT same date extraction logic as the Synaps
    scanner (scanner.py → get_best_date), so organized folders will match
    timeline grouping perfectly.

Usage:
    python scripts/organize_existing_media.py --dry-run      # Preview only
    python scripts/organize_existing_media.py --execute       # Actually move files
    python scripts/organize_existing_media.py --dry-run --verbose   # Detailed preview

After running --execute, restart Synaps backend and it will rescan
automatically. Existing thumbnails are preserved (path-hash based).

Safety:
    - Never deletes files
    - Never overwrites files (skips duplicates)
    - Ignores already-organized YYYY/MM subdirectories
    - Only processes the flat root of the Iphone folder
    - Never touches Synaps v2 vault files (canonical objects, hardlinked/symlinked files,
      anything under Mirrors/)
    - Carries cached thumbnails along with moved files
"""

import os
import sys
import re
import shutil
import logging
import argparse
from datetime import datetime
from pathlib import Path

# ── Import Synaps internals ──────────────────────────────────────────────
# This script lives in backend/ alongside scanner.py, config.py, etc.
# We import directly to guarantee identical date logic.

# Make the backend modules (config, database, ...) importable however this script is started
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from config import ALLOWED_SCAN_PATHS, ALL_MEDIA_EXTENSIONS, STORAGE_PATH
from scanner import (
    get_best_date, extract_exif_date, extract_date_from_filename, extract_video_date,
    vault_protection_reason,
)
from thumbnails import move_thumbnail
from database import SessionLocal
from models import MediaFile

# ── Constants ────────────────────────────────────────────────────────────

UNKNOWN_DATE_FOLDER = "Unknown_Date"
IGNORE_EXTENSIONS = {".aae", ".tmp", ".ds_store"}
YEAR_MONTH_PATTERN = re.compile(r"^\d{4}$")  # Matches "2024", "2025", etc.

# ── Logging ──────────────────────────────────────────────────────────────

logger = logging.getLogger("synaps.organizer")


def setup_logging(verbose: bool = False):
    """Configure console + file logging."""
    level = logging.DEBUG if verbose else logging.INFO
    formatter = logging.Formatter(
        "%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%H:%M:%S",
    )

    # Console
    ch = logging.StreamHandler()
    ch.setLevel(level)
    ch.setFormatter(formatter)

    # File log (always verbose)
    log_dir = os.path.dirname(os.path.abspath(__file__))
    log_path = os.path.join(log_dir, "organize_media.log")
    fh = logging.FileHandler(log_path, mode="w", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(formatter)

    logger.setLevel(logging.DEBUG)
    logger.addHandler(ch)
    logger.addHandler(fh)

    return log_path


# ── Core Logic ───────────────────────────────────────────────────────────

def detect_date_source(filepath: str, filename: str) -> tuple[datetime | None, str]:
    """
    Detect the best date using the SAME priority as Synaps scanner:
        1. EXIF DateTimeOriginal (images)
        2. Video container metadata via ffprobe (MP4/MOV)
        3. Filename pattern (YYYYMMDD)
        4. Filesystem dates (oldest of birthtime/mtime/ctime)

    Returns (date, source_description) for logging.
    """
    # 1. EXIF (images — JPEG via exifread, HEIC via PIL+pillow_heif)
    exif_date = extract_exif_date(filepath)
    if exif_date:
        return exif_date, "EXIF DateTimeOriginal"

    # 2. Video metadata (MP4/MOV creation_time via ffprobe)
    video_date = extract_video_date(filepath)
    if video_date:
        return video_date, "Video creation_time"

    # 3. Filename
    fn_date = extract_date_from_filename(filename)
    if fn_date:
        return fn_date, "Filename pattern"

    # 3. Filesystem dates — prefer birthtime (creation) over mtime (modified)
    # When files are copied/imported, mtime gets reset to copy date.
    # birthtime preserves original creation date on macOS/HFS+/APFS.
    try:
        stat = os.stat(filepath)
        candidates = []

        birth = getattr(stat, 'st_birthtime', None)
        if birth:
            candidates.append(("Filesystem birthtime", datetime.fromtimestamp(birth)))

        if hasattr(stat, 'st_mtime'):
            candidates.append(("Filesystem mtime", datetime.fromtimestamp(stat.st_mtime)))

        candidates.append(("Filesystem ctime", datetime.fromtimestamp(stat.st_ctime)))

        # Pick the oldest valid date (most likely the real capture date)
        now = datetime.now()
        valid = [(src, d) for src, d in candidates if d <= now]
        if valid:
            best_src, best_date = min(valid, key=lambda x: x[1])
            return best_date, best_src
    except OSError:
        pass

    return None, "No date found"


def get_target_folder(base_dir: str, date: datetime | None) -> str:
    """Build target folder path: base_dir/YYYY/MM or base_dir/Unknown_Date."""
    if date is None:
        return os.path.join(base_dir, UNKNOWN_DATE_FOLDER)
    return os.path.join(base_dir, str(date.year), f"{date.month:02d}")


def collect_files(base_dir: str) -> list[str]:
    """
    Collect only flat (non-recursive) media files from base_dir.
    Skips hidden files, temp files, AAE files, and already-organized YYYY/ subdirs.
    """
    files = []
    for entry in os.scandir(base_dir):
        # Skip directories (including existing YYYY/ and Unknown_Date/)
        if entry.is_dir():
            continue

        # Skip hidden files
        if entry.name.startswith("."):
            continue

        # Skip ignored extensions
        ext = os.path.splitext(entry.name)[1].lower()
        if ext in IGNORE_EXTENSIONS:
            continue

        # Only process known media types
        if ext not in ALL_MEDIA_EXTENSIONS:
            logger.debug(f"  SKIP (not media): {entry.name}")
            continue

        files.append(entry.path)

    return sorted(files)


def organize(base_dir: str, dry_run: bool = True, update_db: bool = True) -> dict:
    """
    Main organizer. Processes all flat media files in base_dir.

    Args:
        base_dir:   The Iphone folder path
        dry_run:    If True, only log what would happen
        update_db:  If True, update Synaps DB paths after moving

    Returns:
        Stats dictionary
    """
    stats = {
        "total": 0,
        "moved": 0,
        "skipped_duplicate": 0,
        "skipped_already_organized": 0,
        "skipped_vault": 0,
        "unknown_date": 0,
        "errors": 0,
        "by_source": {"EXIF DateTimeOriginal": 0, "Filename pattern": 0, "Filesystem mtime": 0, "No date found": 0},
    }

    mode_label = "DRY RUN" if dry_run else "EXECUTING"
    logger.info(f"{'=' * 60}")
    logger.info(f"  Synaps Media Organizer — {mode_label}")
    logger.info(f"  Source: {base_dir}")
    logger.info(f"  Date logic: Synaps scanner.get_best_date()")
    logger.info(f"{'=' * 60}")

    if not os.path.isdir(base_dir):
        logger.error(f"Directory does not exist: {base_dir}")
        return stats

    # Collect files (flat only, no recursion)
    files = collect_files(base_dir)
    stats["total"] = len(files)
    logger.info(f"Found {len(files)} media files to process\n")

    if len(files) == 0:
        logger.info("Nothing to do — folder is empty or already organized.")
        return stats

    # Open DB session for path updates
    db = None
    if update_db and not dry_run:
        try:
            db = SessionLocal()
        except Exception as e:
            logger.warning(f"Could not open DB session: {e}. Paths won't be updated.")
    # Separate read-only session for the v2 vault check (also in dry-run / --no-db)
    vault_db = None
    try:
        vault_db = SessionLocal()
    except Exception as e:
        logger.warning(f"Could not open DB session for vault checks: {e}")

    try:
        for i, filepath in enumerate(files, 1):
            filename = os.path.basename(filepath)

            try:
                vault_reason = vault_protection_reason(filepath, vault_db)
            except OSError as e:
                vault_reason = f"can't be inspected ({e})"
            if vault_reason:
                stats["skipped_vault"] += 1
                logger.info(f"  [{i}/{len(files)}] SKIP (vault): {filename} {vault_reason}")
                continue

            # Detect date using Synaps scanner logic
            date, source = detect_date_source(filepath, filename)
            stats["by_source"][source] = stats["by_source"].get(source, 0) + 1

            if date is None:
                stats["unknown_date"] += 1

            # Build target path
            target_dir = get_target_folder(base_dir, date)
            target_path = os.path.join(target_dir, filename)

            # Format date for logging
            date_str = date.strftime("%Y-%m-%d %H:%M") if date else "UNKNOWN"
            month_str = date.strftime("%Y/%m") if date else "Unknown_Date"

            # Check for duplicates
            if os.path.exists(target_path):
                stats["skipped_duplicate"] += 1
                logger.debug(f"  [{i}/{len(files)}] SKIP (exists): {filename} → {month_str}/")
                continue

            # Log the planned move
            if dry_run:
                logger.info(f"  [{i}/{len(files)}] {filename}  →  {month_str}/  (date: {date_str}, via: {source})")
            else:
                # Create target directory
                os.makedirs(target_dir, exist_ok=True)

                try:
                    shutil.move(filepath, target_path)
                    stats["moved"] += 1
                    move_thumbnail(filepath, target_path)
                    logger.info(f"  [{i}/{len(files)}] MOVED: {filename}  →  {month_str}/  (via: {source})")

                    # Update the DB record with the new path
                    if db:
                        media = db.query(MediaFile).filter(MediaFile.path == filepath).first()
                        if media:
                            media.path = target_path
                            rel_path = os.path.relpath(target_path, STORAGE_PATH)
                            media.relative_path = rel_path
                            media.directory = os.path.relpath(target_dir, STORAGE_PATH)
                            # Commit every 50 moves to avoid large transactions
                            if stats["moved"] % 50 == 0:
                                db.commit()

                except Exception as e:
                    stats["errors"] += 1
                    logger.error(f"  [{i}/{len(files)}] ERROR: {filename}: {e}")

            # Progress indicator for large batches
            if i % 200 == 0:
                logger.info(f"  ... processed {i}/{len(files)} files ...")

        # Final DB commit
        if db:
            db.commit()

    finally:
        if db:
            db.close()
        if vault_db:
            vault_db.close()

    # ── Summary ──
    logger.info(f"\n{'=' * 60}")
    logger.info(f"  SUMMARY — {mode_label}")
    logger.info(f"{'=' * 60}")
    logger.info(f"  Total files scanned:    {stats['total']}")

    if dry_run:
        would_move = stats["total"] - stats["skipped_duplicate"] - stats["skipped_vault"]
        logger.info(f"  Would move:             {would_move}")
    else:
        logger.info(f"  Successfully moved:     {stats['moved']}")

    logger.info(f"  Skipped (duplicate):    {stats['skipped_duplicate']}")
    logger.info(f"  Skipped (vault files):  {stats['skipped_vault']}")
    logger.info(f"  Unknown date:           {stats['unknown_date']}")
    logger.info(f"  Errors:                 {stats['errors']}")
    logger.info(f"")
    logger.info(f"  Date sources used:")
    for src, count in sorted(stats["by_source"].items(), key=lambda x: -x[1]):
        if count > 0:
            logger.info(f"    {src}: {count}")
    logger.info(f"{'=' * 60}")

    if dry_run:
        logger.info(f"\n  This was a DRY RUN. No files were moved.")
        logger.info(f"  To execute, run:  python scripts/organize_existing_media.py --execute\n")

    return stats


# ── CLI ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Synaps Media Organizer — Reorganize flat iPhone media into YYYY/MM folders.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python scripts/organize_existing_media.py --dry-run             Preview changes
  python scripts/organize_existing_media.py --dry-run --verbose   Detailed preview
  python scripts/organize_existing_media.py --execute             Move files for real
  python scripts/organize_existing_media.py --execute --no-db     Move without DB update

Safety:
  - Always run --dry-run first to verify
  - Files are NEVER deleted or overwritten
  - Duplicates are safely skipped
  - Log file saved to organize_media.log
        """,
    )

    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="Preview moves without touching files")
    mode.add_argument("--execute", action="store_true", help="Actually move files")

    parser.add_argument("--verbose", "-v", action="store_true", help="Show debug-level output")
    parser.add_argument("--no-db", action="store_true", help="Skip updating Synaps database paths")
    parser.add_argument(
        "--path",
        type=str,
        default=None,
        help="Override the source directory (defaults to ALLOWED_SCAN_PATHS[0])",
    )

    args = parser.parse_args()

    log_path = setup_logging(verbose=args.verbose)
    logger.info(f"Log file: {log_path}")

    # Resolve target directory
    if args.path:
        base_dir = args.path
    elif ALLOWED_SCAN_PATHS:
        base_dir = ALLOWED_SCAN_PATHS[0]
    else:
        logger.error("No scan path configured. Set ALLOWED_SCAN_PATHS in config.py or use --path")
        sys.exit(1)

    if not os.path.isdir(base_dir):
        logger.error(f"Directory does not exist: {base_dir}")
        logger.error(f"Check your .env SYNAPS_STORAGE_PATH and config.py ALLOWED_SCAN_PATHS")
        sys.exit(1)

    mirrors = os.path.join(os.path.realpath(STORAGE_PATH), "Mirrors")
    real_base = os.path.realpath(base_dir)
    if real_base == mirrors or real_base.startswith(mirrors + os.sep):
        logger.error("Refusing to reorganize Mirrors/: it is managed by the Synaps vault")
        sys.exit(1)

    # Safety confirmation for execute mode
    if args.execute:
        print(f"\n  ⚠️  EXECUTE MODE — This will move files in:\n  {base_dir}\n")
        confirm = input("  Type 'yes' to proceed: ").strip().lower()
        if confirm != "yes":
            print("  Aborted.")
            sys.exit(0)

    stats = organize(
        base_dir=base_dir,
        dry_run=args.dry_run,
        update_db=not args.no_db,
    )

    if stats["errors"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
