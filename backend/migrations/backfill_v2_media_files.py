#!/usr/bin/env python3
"""
One-off backfill: give every v2 canonical Vault file (physical_objects) a v1 media_files row,
so the web timeline / thumbnails / file endpoints show what the Mac and iPhone apps uploaded
before uploads did this themselves. Mirrors/ are never indexed (they are hardlinks of the same
files). Idempotent: rows are keyed by the unique media_files.path and existing rows are not
recreated, so it is safe to re-run.

For rows that already exist at a canonical path (e.g. from a manual /api/scan) it also fills a
missing content_hash and replaces a meaningless `source` (the scanner derives it from the
folder name, which under Vault/YYYY/MM is the month) with the uploading device's source.

Usage (from backend/, venv active; running server is fine, idle is better):
    python migrations/backfill_v2_media_files.py --dry-run
    python migrations/backfill_v2_media_files.py
Options:
    --dry-run                report what would change, write nothing
    --fix-reference-counts   recompute physical_objects.reference_count from logical_items
    --fix-capture-dates      set media_metadata.capture_date from the file's EXIF/video/filename
                             date when it differs (older uploads stored the upload time); the
                             file itself stays in its Vault/YYYY/MM folder
    --batch-size N           commit every N new rows (default 200)
"""
import os
import sys
import argparse
from collections import Counter

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from sqlalchemy import func, inspect
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import selectinload

from config import STORAGE_PATH, SOURCE_MAPPING
from database import SessionLocal, engine
from models import MediaFile
from models_v2 import PhysicalObject, LogicalItem, Source
from scanner import extract_exif_date, extract_video_date, extract_date_from_filename
from routers.ingest_v2 import upsert_v1_media_file, v1_source_key, SHA_PREFIX_RE

KNOWN_SOURCES = set(SOURCE_MAPPING.values())


def embedded_date(full_path: str):
    """EXIF / video container / filename date of the canonical file, or None."""
    display = SHA_PREFIX_RE.sub("", os.path.basename(full_path))
    for extract in (lambda: extract_exif_date(full_path),
                    lambda: extract_video_date(full_path),
                    lambda: extract_date_from_filename(display)):
        try:
            found = extract()
        except Exception:
            found = None
        if found:
            return found
    return None


def first_logical_items(db, phys_ids):
    """physical_object_id -> (earliest LogicalItem, its Source)"""
    out = {}
    rows = (
        db.query(LogicalItem, Source)
        .join(Source, Source.id == LogicalItem.source_id)
        .filter(LogicalItem.physical_object_id.in_(phys_ids))
        .order_by(LogicalItem.imported_at.asc())
        .all()
    )
    for logical, source in rows:
        out.setdefault(logical.physical_object_id, (logical, source))
    return out


def commit_batch(db, stats, dry_run, new_rows=0) -> bool:
    if dry_run:
        db.rollback()
        return True
    try:
        db.commit()
        return True
    except IntegrityError:
        # A concurrent upload created one of these rows meanwhile; re-running fixes the rest
        db.rollback()
        stats["created"] -= new_rows
        stats["conflicts"] += 1
        return False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--fix-reference-counts", action="store_true")
    parser.add_argument("--fix-capture-dates", action="store_true")
    parser.add_argument("--batch-size", type=int, default=200)
    args = parser.parse_args()

    print(f"Storage root: {STORAGE_PATH}")
    print(f"Database:     {engine.url}")
    print("Mode:         " + ("DRY RUN (no changes)" if args.dry_run else "APPLY"))

    tables = set(inspect(engine).get_table_names())
    if not {"physical_objects", "media_files"} <= tables:
        print("No v2 tables in this database - nothing to backfill.")
        return 0

    stats = Counter()
    db = SessionLocal()
    try:
        total = db.query(func.count(PhysicalObject.id)).scalar() or 0
        print(f"Physical objects: {total}")

        offset = 0
        while True:
            batch = (
                db.query(PhysicalObject)
                .options(selectinload(PhysicalObject.metadata_record))
                .order_by(PhysicalObject.created_at.asc(), PhysicalObject.id.asc())
                .offset(offset)
                .limit(args.batch_size)
                .all()
            )
            if not batch:
                break
            offset += len(batch)
            provenance = first_logical_items(db, [p.id for p in batch])
            new_rows = 0

            for phys in batch:
                rel = phys.physical_path or ""
                if not rel.replace("\\", "/").startswith("Vault/"):
                    stats["skipped_not_vault"] += 1
                    continue
                full = os.path.join(STORAGE_PATH, rel)
                if not os.path.isfile(full):
                    stats["missing_on_disk"] += 1
                    continue

                logical, source = provenance.get(phys.id, (None, None))
                meta = phys.metadata_record
                existing = db.query(MediaFile).filter(MediaFile.path == full).first()
                found_date = embedded_date(full) if (args.fix_capture_dates or not existing) else None

                if args.fix_capture_dates and meta is not None and found_date and meta.capture_date != found_date:
                    stats["capture_dates_fixed"] += 1
                    meta.capture_date = found_date

                if existing:
                    stats["already_indexed"] += 1
                    if not existing.content_hash:
                        existing.content_hash = phys.sha256
                        stats["content_hash_filled"] += 1
                    if source is not None and existing.source not in KNOWN_SOURCES:
                        wanted = v1_source_key(source.id, source.platform)
                        if existing.source != wanted:
                            existing.source = wanted
                            stats["source_fixed"] += 1
                    continue

                # Without an embedded date, the old ingest stored the upload time as
                # capture_date, so the device's creation time is the better guess
                date_taken = (
                    found_date
                    or (logical.source_created_at if logical else None)
                    or (meta.capture_date if meta else None)
                )
                if upsert_v1_media_file(db, phys, meta, source, date_taken=date_taken) is None:
                    stats["skipped_not_media"] += 1
                    continue
                stats["created"] += 1
                new_rows += 1

            commit_batch(db, stats, args.dry_run, new_rows)
            print(f"  processed {offset}/{total}")

        if args.fix_reference_counts:
            actual = dict(
                db.query(LogicalItem.physical_object_id, func.count(LogicalItem.id))
                .group_by(LogicalItem.physical_object_id)
                .all()
            )
            for phys in db.query(PhysicalObject).all():
                want = actual.get(phys.id, 0)
                if (phys.reference_count or 0) != want:
                    stats["reference_counts_fixed"] += 1
                    phys.reference_count = want
            commit_batch(db, stats, args.dry_run)
    finally:
        db.close()

    print("")
    verb = "Would" if args.dry_run else "Did"
    print(f"{verb} create media_files rows:      {stats['created']}")
    print(f"Already indexed (canonical path):    {stats['already_indexed']}")
    print(f"{verb} fill missing content_hash:    {stats['content_hash_filled']}")
    print(f"{verb} fix meaningless source:       {stats['source_fixed']}")
    if args.fix_capture_dates:
        print(f"{verb} fix capture dates:            {stats['capture_dates_fixed']}")
    if args.fix_reference_counts:
        print(f"{verb} fix reference counts:         {stats['reference_counts_fixed']}")
    print(f"Skipped (not a photo/video):         {stats['skipped_not_media']}")
    print(f"Skipped (missing on disk):           {stats['missing_on_disk']}")
    print(f"Skipped (not under Vault/):          {stats['skipped_not_vault']}")
    if stats["conflicts"]:
        print(f"Batches skipped (concurrent upload): {stats['conflicts']} - run the script again")
    if not args.dry_run and stats["created"]:
        print("Thumbnails are generated on first view (or run preheat_thumbnails.py).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
