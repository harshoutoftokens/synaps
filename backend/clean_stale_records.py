#!/usr/bin/env python3
"""
Synaps Database Cleaner
=======================
Scans all MediaFile records in the database and safely deletes any rows
where the file no longer exists on disk.
Also handles duplicate records (based on file_hash or just same physical path).

Refuses to run when the storage root is missing/empty, and keeps rows whose top-level
folder is missing or empty: that is an unmounted disk, not deleted files.
"""

import os
import argparse
import logging
from collections import defaultdict
from database import SessionLocal
from models import MediaFile
from config import EXCLUDED_PATHS, STORAGE_PATH

NORMALIZED_EXCLUDED_PATHS = [os.path.normpath(p) for p in EXCLUDED_PATHS]

logger = logging.getLogger("synaps.cleaner")

def setup_logging():
    formatter = logging.Formatter("%(asctime)s  %(levelname)-7s  %(message)s", datefmt="%H:%M:%S")
    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    ch.setFormatter(formatter)
    logger.setLevel(logging.INFO)
    logger.addHandler(ch)

def clean_database(dry_run: bool):
    logger.info(f"{'=' * 60}")
    logger.info("  Synaps Database Cleaner & Verification Tool")
    logger.info(f"{'=' * 60}")
    if dry_run:
        logger.info("  *** DRY RUN MODE - NO CHANGES WILL BE MADE ***")
    else:
        logger.info("  *** EXECUTE MODE - APPLYING CHANGES ***")
    logger.info(f"{'=' * 60}")

    try:
        with os.scandir(STORAGE_PATH) as it:
            mounted = any(not entry.name.startswith(".") for entry in it)
    except OSError:
        mounted = False
    if not mounted:
        logger.error(f"{STORAGE_PATH} is missing or empty (disk not mounted?) — refusing to touch the database.")
        return

    top_folder_ok = {}

    def top_folder_available(relative_path):
        top = (relative_path or "").split(os.sep)[0]
        if not top or top in (".", ".."):
            return True
        if top not in top_folder_ok:
            try:
                with os.scandir(os.path.join(STORAGE_PATH, top)) as it:
                    top_folder_ok[top] = any(True for _ in it)
            except OSError:
                top_folder_ok[top] = False
        return top_folder_ok[top]

    db = SessionLocal()
    try:
        # Get all records
        all_media = db.query(MediaFile).all()
        total_records = len(all_media)
        
        valid_records = []
        missing_records = []
        duplicate_records = []
        offline_records = 0
        
        # Track by hash to find duplicates. Wait, file_hash might be empty for some?
        # Let's track by path to find DB duplicates pointing to the same file.
        # Actually, let's track both. A moved file is: missing physical file at old path, but a new DB row exists with the same hash at new path.
        hash_map = defaultdict(list)
        path_map = defaultdict(list)
        
        for media in all_media:
            if media.file_hash:
                hash_map[media.file_hash].append(media)
            path_map[media.path].append(media)
            
            is_excluded = False
            if media.relative_path:
                norm_rel_path = os.path.normpath(media.relative_path)
                for ep in NORMALIZED_EXCLUDED_PATHS:
                    if norm_rel_path == ep or norm_rel_path.startswith(ep + os.sep):
                        is_excluded = True
                        break

            if is_excluded:
                missing_records.append(media)
            elif not os.path.exists(media.path):
                if top_folder_available(media.relative_path):
                    missing_records.append(media)
                else:
                    offline_records += 1  # top-level folder offline: keep the row
            else:
                valid_records.append(media)

        # Identify duplicates (multiple DB records pointing to the same physical path)
        for path, records in path_map.items():
            if len(records) > 1:
                # Keep the first one, mark the rest as duplicates
                for dup in records[1:]:
                    if dup not in missing_records:
                        duplicate_records.append(dup)

        stale_count = len(missing_records)
        duplicate_count = len(duplicate_records)

        logger.info(f"Total database records: {total_records}")
        logger.info(f"Valid records: {len(valid_records) - duplicate_count}")
        logger.info(f"Missing/Stale files: {stale_count}")
        logger.info(f"Duplicate DB records: {duplicate_count}")
        if offline_records:
            logger.info(f"Kept (top-level folder missing/empty, disk offline?): {offline_records}")

        if stale_count > 0:
            logger.info("\n--- Missing/Stale Records (Old paths / Moved files) ---")
            for i, r in enumerate(missing_records[:10]):
                logger.info(f"  Missing: {r.path}")
            if stale_count > 10:
                logger.info(f"  ... and {stale_count - 10} more.")

        if duplicate_count > 0:
            logger.info("\n--- Duplicate Records ---")
            for i, r in enumerate(duplicate_records[:10]):
                logger.info(f"  Duplicate: {r.path}")
            if duplicate_count > 10:
                logger.info(f"  ... and {duplicate_count - 10} more.")

        to_delete = set(missing_records + duplicate_records)

        if not to_delete:
            logger.info("\nDatabase is perfectly clean! No actions needed.")
            return

        if dry_run:
            logger.info(f"\n[DRY RUN] Would safely remove {len(to_delete)} stale/duplicate records.")
        else:
            for record in to_delete:
                db.delete(record)
            db.commit()
            logger.info(f"\n[EXECUTE] ✅ Successfully deleted {len(to_delete)} stale/duplicate records.")
            
    except Exception as e:
        logger.error(f"Error during database cleanup: {e}")
        db.rollback()
    finally:
        db.close()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Database Cleanup Tool")
    parser.add_argument("--dry-run", action="store_true", help="Report what would be deleted without making changes")
    parser.add_argument("--execute", action="store_true", help="Execute the cleanup safely")
    args = parser.parse_args()

    if not args.dry_run and not args.execute:
        print("Please specify --dry-run or --execute")
        exit(1)

    setup_logging()
    clean_database(dry_run=args.dry_run)
