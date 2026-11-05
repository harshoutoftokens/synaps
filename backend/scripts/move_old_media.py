#!/usr/bin/env python3
"""
Synaps Old Media Migrator — Move pre-iPhone photos flat into Old_Photos/
========================================================================
Moves all actual photo/video FILES from old year folders (2008-2023)
into a single flat Old_Photos/ folder. No subfolders inside Old_Photos/.

Usage:
    python scripts/move_old_media.py --dry-run                         # Preview
    python scripts/move_old_media.py --dry-run --cutoff 2023           # Custom cutoff
    python scripts/move_old_media.py --execute                         # Move for real
    python scripts/move_old_media.py --execute --path /storage/...     # NAS path

Safety:
    - Never deletes files
    - Never overwrites — renames duplicates with a suffix
    - Never touches Synaps v2 vault files (canonical Vault/YYYY/MM objects, hardlinked
      or symlinked files, Mirrors/) — refuses to run on the Vault root or Mirrors/
    - Updates media_files paths (keeps favorites) and carries cached thumbnails along
    - Cleans up empty folders after moving
    - Logs every operation
"""

import os
import sys
import re
import shutil
import logging
import argparse
from pathlib import Path

# Make the backend modules (config, database, ...) importable however this script is started
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from config import ALLOWED_SCAN_PATHS, ALL_MEDIA_EXTENSIONS, STORAGE_PATH

# ── Logging ──────────────────────────────────────────────────────────────

logger = logging.getLogger("synaps.old_media_migrator")


def setup_logging(verbose: bool = False):
    level = logging.DEBUG if verbose else logging.INFO
    formatter = logging.Formatter(
        "%(asctime)s  %(levelname)-7s  %(message)s",
        datefmt="%H:%M:%S",
    )

    ch = logging.StreamHandler()
    ch.setLevel(level)
    ch.setFormatter(formatter)

    log_dir = os.path.dirname(os.path.abspath(__file__))
    log_path = os.path.join(log_dir, "move_old_media.log")
    fh = logging.FileHandler(log_path, mode="w", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(formatter)

    logger.setLevel(logging.DEBUG)
    logger.addHandler(ch)
    logger.addHandler(fh)

    return log_path


# ── Core Logic ───────────────────────────────────────────────────────────

def find_year_folders(base_dir: str, cutoff_year: int) -> list[tuple[str, int]]:
    """Find YYYY/ folders where year < cutoff."""
    year_pattern = re.compile(r"^\d{4}$")
    results = []

    for entry in sorted(os.scandir(base_dir), key=lambda e: e.name):
        if not entry.is_dir():
            continue
        if not year_pattern.match(entry.name):
            continue
        year = int(entry.name)
        if year < cutoff_year:
            results.append((entry.path, year))

    return results


def collect_all_files(folder_path: str) -> list[str]:
    """Recursively collect all media files from a folder."""
    files = []
    for root, dirs, filenames in os.walk(folder_path):
        for f in filenames:
            if f.startswith("."):
                continue
            ext = os.path.splitext(f)[1].lower()
            if ext in ALL_MEDIA_EXTENSIONS:
                files.append(os.path.join(root, f))
    return files


def safe_destination(dest_dir: str, filename: str) -> str:
    """
    Return a safe destination path. If filename already exists in dest_dir,
    append _1, _2, etc. to avoid overwriting.
    """
    dest = os.path.join(dest_dir, filename)
    if not os.path.exists(dest):
        return dest

    name, ext = os.path.splitext(filename)
    counter = 1
    while True:
        new_name = f"{name}_{counter}{ext}"
        dest = os.path.join(dest_dir, new_name)
        if not os.path.exists(dest):
            return dest
        counter += 1


def remove_empty_dirs(path: str):
    """Remove a directory tree if all directories are empty (bottom-up)."""
    for root, dirs, files in os.walk(path, topdown=False):
        for d in dirs:
            dirpath = os.path.join(root, d)
            try:
                if not os.listdir(dirpath):
                    os.rmdir(dirpath)
                    logger.debug(f"  Removed empty dir: {dirpath}")
            except OSError:
                pass
    # Remove the top-level folder itself if empty
    try:
        if os.path.isdir(path) and not os.listdir(path):
            os.rmdir(path)
            logger.debug(f"  Removed empty dir: {path}")
    except OSError:
        pass


def unsafe_base_reason(base_dir: str):
    """Why base_dir must not be reorganized (None if it is fine)."""
    real = os.path.realpath(base_dir)
    storage = os.path.realpath(STORAGE_PATH)
    if real == os.path.join(storage, "Vault"):
        return "the Vault root holds the v2 canonical YYYY/MM folders"
    mirrors = os.path.join(storage, "Mirrors")
    if real == mirrors or real.startswith(mirrors + os.sep):
        return "Mirrors/ is managed by the Synaps vault"
    return None


def _update_db_path(db, old_path: str, new_path: str) -> None:
    from models import MediaFile
    media = db.query(MediaFile).filter(MediaFile.path == old_path).first()
    if media:
        media.path = new_path
        media.relative_path = os.path.relpath(new_path, STORAGE_PATH)
        media.directory = os.path.relpath(os.path.dirname(new_path), STORAGE_PATH)
        media.filename = os.path.basename(new_path)


def move_old_media(
    base_dir: str,
    cutoff_year: int,
    dry_run: bool = True,
    update_db: bool = True,
) -> dict:
    """
    Move all files from old year folders flat into Old_Photos/.

    Example:
        /Iphone/2015/03/photo.jpg  →  /Iphone/Old_Photos/photo.jpg
        /Iphone/2008/01/img.heic   →  /Iphone/Old_Photos/img.heic
    """
    stats = {
        "files_moved": 0,
        "files_renamed": 0,  # duplicates that were renamed with _1, _2 etc.
        "skipped_vault": 0,  # v2 vault files left alone
        "folders_cleaned": 0,
        "errors": 0,
    }

    old_photos_dir = os.path.join(base_dir, "Old_Photos")
    mode_label = "DRY RUN" if dry_run else "EXECUTING"

    logger.info(f"{'=' * 60}")
    logger.info(f"  Synaps Old Media Migrator — {mode_label}")
    logger.info(f"  Source: {base_dir}")
    logger.info(f"  Cutoff: Years before {cutoff_year} → Old_Photos/")
    logger.info(f"  Destination: {old_photos_dir}  (flat, no subfolders)")
    logger.info(f"{'=' * 60}")

    # Find old year folders
    old_folders = find_year_folders(base_dir, cutoff_year)

    if not old_folders:
        logger.info(f"\n  No year folders found before {cutoff_year}. Nothing to do.")
        return stats

    # Collect all files from old folders
    all_files = []
    for folder_path, year in old_folders:
        files = collect_all_files(folder_path)
        logger.info(f"  📁 {year}/  →  {len(files)} files")
        all_files.extend((f, year, folder_path) for f in files)

    logger.info(f"\n  Total: {len(all_files)} files to move into Old_Photos/\n")

    if not all_files:
        logger.info("  All old folders are empty. Nothing to move.")
        return stats

    # DB session: v2 vault lookups (both modes) and path updates (execute mode)
    db = None
    try:
        from database import SessionLocal
        db = SessionLocal()
    except Exception as e:
        logger.warning(f"  Could not open DB session ({e}); vault checks use the file layout only")

    try:
        _move_all(all_files, old_photos_dir, dry_run, update_db, db, stats)
    finally:
        if db:
            db.close()

    # Clean up empty year/month folders
    if not dry_run:
        logger.info(f"\n  Cleaning up empty folders...")
        for folder_path, year in old_folders:
            remove_empty_dirs(folder_path)
            if not os.path.exists(folder_path):
                stats["folders_cleaned"] += 1
                logger.info(f"  🗑️  Removed empty: {year}/")

    # Summary
    logger.info(f"\n{'=' * 60}")
    logger.info(f"  SUMMARY — {mode_label}")
    logger.info(f"{'=' * 60}")
    logger.info(f"  Files {'would move' if dry_run else 'moved'}:     {stats['files_moved']}")
    logger.info(f"  Renamed (duplicates):  {stats['files_renamed']}")
    logger.info(f"  Skipped (vault files): {stats['skipped_vault']}")
    logger.info(f"  Empty folders cleaned: {stats['folders_cleaned']}")
    logger.info(f"  Errors:                {stats['errors']}")
    logger.info(f"{'=' * 60}")

    if dry_run:
        logger.info(f"\n  This was a DRY RUN. No files were moved.")
        logger.info(f"  To execute, run:  python scripts/move_old_media.py --execute\n")

    return stats


def _move_all(all_files, old_photos_dir, dry_run, update_db, db, stats):
    from scanner import vault_protection_reason
    from thumbnails import move_thumbnail

    # Move each file flat into Old_Photos/
    for filepath, year, folder_path in all_files:
        filename = os.path.basename(filepath)
        try:
            reason = vault_protection_reason(filepath, db)
        except OSError as e:
            reason = f"can't be inspected ({e})"
        if reason:
            stats["skipped_vault"] += 1
            logger.info(f"  SKIP {year}/ {filename}: {reason}")
            continue
        dest = safe_destination(old_photos_dir, filename)
        dest_filename = os.path.basename(dest)

        was_renamed = dest_filename != filename

        if dry_run:
            if was_renamed:
                logger.info(f"  {year}/ {filename}  →  Old_Photos/{dest_filename}  (renamed)")
                stats["files_renamed"] += 1
            else:
                logger.info(f"  {year}/ {filename}  →  Old_Photos/{filename}")
            stats["files_moved"] += 1
        else:
            try:
                os.makedirs(old_photos_dir, exist_ok=True)
                shutil.move(filepath, dest)
                stats["files_moved"] += 1
                move_thumbnail(filepath, dest)
                if db and update_db:
                    _update_db_path(db, filepath, dest)
                    if stats["files_moved"] % 50 == 0:
                        db.commit()

                if was_renamed:
                    stats["files_renamed"] += 1
                    logger.info(f"  ✅ {year}/ {filename}  →  Old_Photos/{dest_filename}  (renamed)")
                else:
                    logger.info(f"  ✅ {year}/ {filename}  →  Old_Photos/{filename}")

            except Exception as e:
                stats["errors"] += 1
                logger.error(f"  ❌ ERROR: {filename}: {e}")

    if db and update_db and not dry_run:
        db.commit()


# ── CLI ──────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="Move old year folders flat into Old_Photos/.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python scripts/move_old_media.py --dry-run                    Preview (cutoff: 2024)
  python scripts/move_old_media.py --dry-run --cutoff 2023      Only before 2023 is "old"
  python scripts/move_old_media.py --execute                    Move for real
  python scripts/move_old_media.py --execute --path /storage/Vault/Harsh/Iphone

Result:
  /Iphone/2008/01/photo.jpg  →  /Iphone/Old_Photos/photo.jpg
  /Iphone/2015/03/img.heic   →  /Iphone/Old_Photos/img.heic
  /Iphone/2024/ stays (modern timeline)
  /Iphone/2025/ stays (modern timeline)

  Empty old year/month folders are automatically removed.
        """,
    )

    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="Preview without moving")
    mode.add_argument("--execute", action="store_true", help="Actually move files")

    parser.add_argument(
        "--cutoff", type=int, default=2024,
        help="Year cutoff: files from folders BEFORE this year are moved (default: 2024)"
    )
    parser.add_argument("--verbose", "-v", action="store_true", help="Detailed output")
    parser.add_argument("--no-db", action="store_true", help="Don't update media_files paths")
    parser.add_argument(
        "--path", type=str, default=None,
        help="Override source directory (defaults to ALLOWED_SCAN_PATHS[0])"
    )

    args = parser.parse_args()

    log_path = setup_logging(verbose=args.verbose)
    logger.info(f"Log file: {log_path}")

    if args.path:
        base_dir = args.path
    elif ALLOWED_SCAN_PATHS:
        base_dir = ALLOWED_SCAN_PATHS[0]
    else:
        logger.error("No scan path configured. Use --path to specify.")
        sys.exit(1)

    if not os.path.isdir(base_dir):
        logger.error(f"Directory does not exist: {base_dir}")
        sys.exit(1)

    unsafe = unsafe_base_reason(base_dir)
    if unsafe:
        logger.error(f"Refusing to reorganize {base_dir}: {unsafe}. Point --path at a device folder, e.g. Vault/Harsh/Iphone")
        sys.exit(1)

    if args.execute:
        print(f"\n  ⚠️  EXECUTE MODE")
        print(f"  Will move all files from folders before {args.cutoff}/ flat into Old_Photos/")
        print(f"  Source: {base_dir}\n")
        confirm = input("  Type 'yes' to proceed: ").strip().lower()
        if confirm != "yes":
            print("  Aborted.")
            sys.exit(0)

    move_old_media(
        base_dir=base_dir,
        cutoff_year=args.cutoff,
        dry_run=args.dry_run,
        update_db=not args.no_db,
    )


if __name__ == "__main__":
    main()
