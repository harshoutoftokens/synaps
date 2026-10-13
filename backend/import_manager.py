"""
Synaps Import Manager — Manual import workflow for organizing media
from an import staging folder into the Synaps media library.

Design:
    - NO automatic watchers or background triggers
    - Import only starts when user explicitly clicks a button
    - Reuses EXACT same date/hash/classification logic as scanner.py
    - In-memory job store for progress tracking (poll-based)
    - Designed for extension (Android, Camera, Family imports)
"""

import os
import shutil
import logging
import threading
import uuid
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional

from sqlalchemy.orm import Session

from config import (
    IMPORT_SOURCE_DIR, IMPORT_DEST_BASE, IMPORT_OLD_PHOTOS_CUTOFF,
    IMAGE_EXTENSIONS, VIDEO_EXTENSIONS, ALL_MEDIA_EXTENSIONS,
    STORAGE_PATH, SOURCE_MAPPING,
)
from scanner import (
    get_best_date, compute_content_hash, classify_media,
)
from models import MediaFile, SyncRecord
from models_v2 import PhysicalObject
from database import SessionLocal
from storage_engine import claim_unique_path

logger = logging.getLogger("synaps.import_manager")

# ── Ignore list ──────────────────────────────────────────────────────────
IGNORE_EXTENSIONS = {".aae", ".tmp", ".ds_store"}


# ── Import Job (in-memory progress tracking) ─────────────────────────────

@dataclass
class ImportJob:
    """Represents a running or completed import job."""
    id: str
    status: str = "pending"          # pending | scanning | importing | indexing | complete | error
    phase: str = ""                  # Human-readable phase description
    progress: int = 0                # 0–100
    total_files: int = 0
    processed_files: int = 0
    imported: int = 0
    duplicates_skipped: int = 0
    unknown_date: int = 0
    errors: int = 0
    error_log: list[str] = field(default_factory=list)
    preview_destinations: Optional[dict[str, int]] = None
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    def to_dict(self) -> dict:
        return {
            "job_id": self.id,
            "status": self.status,
            "phase": self.phase,
            "progress": self.progress,
            "total_files": self.total_files,
            "processed_files": self.processed_files,
            "imported": self.imported,
            "duplicates_skipped": self.duplicates_skipped,
            "unknown_date": self.unknown_date,
            "errors": self.errors,
            "error_log": self.error_log,  # Full log to see all duplicates
            "preview_destinations": self.preview_destinations,
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }


# ── Job Store (in-memory, singleton) ─────────────────────────────────────

class _JobStore:
    """Thread-safe in-memory job store."""

    def __init__(self):
        self._jobs: dict[str, ImportJob] = {}
        self._lock = threading.Lock()

    def create(self) -> ImportJob:
        job = ImportJob(id=str(uuid.uuid4())[:8])
        with self._lock:
            self._jobs[job.id] = job
        return job

    def get(self, job_id: str) -> Optional[ImportJob]:
        with self._lock:
            return self._jobs.get(job_id)

    def get_latest(self) -> Optional[ImportJob]:
        with self._lock:
            if not self._jobs:
                return None
            return max(self._jobs.values(), key=lambda j: j.started_at or datetime.min)


job_store = _JobStore()

# Makes "is an import already running? if not, start one" atomic (two clicks / tabs)
_start_lock = threading.Lock()


# ── File Collection ──────────────────────────────────────────────────────

def _collect_import_files(source_dir: str) -> list[str]:
    """
    Recursively collect all supported media files from the import folder.
    Skips hidden files, temp files, AAE sidecar files.
    """
    files = []
    if not os.path.isdir(source_dir):
        logger.warning(f"Import source does not exist: {source_dir}")
        return files

    for root, dirs, filenames in os.walk(source_dir):
        # Skip hidden directories
        dirs[:] = [d for d in dirs if not d.startswith('.')]

        for filename in filenames:
            # Skip hidden files
            if filename.startswith('.'):
                continue

            ext = os.path.splitext(filename)[1].lower()

            # Skip ignored extensions
            if ext in IGNORE_EXTENSIONS:
                continue

            # Only process supported media
            if ext not in ALL_MEDIA_EXTENSIONS:
                continue

            files.append(os.path.join(root, filename))

    return sorted(files)


def _format_size(size_bytes: int) -> str:
    """Format bytes into human-readable string."""
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 ** 2:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 ** 3:
        return f"{size_bytes / (1024 ** 2):.1f} MB"
    else:
        return f"{size_bytes / (1024 ** 3):.1f} GB"


def _get_destination(filepath: str, filename: str) -> tuple[str, str]:
    """
    Determine destination path for a file using Synaps date logic.

    Returns:
        (full_dest_path, relative_dest_label)

    Destination rules:
        date >= 2024  →  Timeline/YYYY/MM/filename
        date < 2024   →  Old_Photos/filename
        no date       →  Unknown_Date/filename
    """
    date = get_best_date(filepath, filename)

    if date is None or (date.year == datetime.now().year and date.month == datetime.now().month and date.day == datetime.now().day):
        # get_best_date falls back to datetime.now() when it can't determine date.
        # If the date is exactly "now", treat as unknown.
        # However, get_best_date always returns a date (falls back to filesystem).
        # We need to check if it actually found a real date or just used fallback.
        # Since get_best_date never returns None, we need a different approach.
        pass

    # get_best_date always returns a datetime (never None), so we use it directly.
    # The date routing is straightforward:
    if date.year < IMPORT_OLD_PHOTOS_CUTOFF:
        dest_dir = os.path.join(IMPORT_DEST_BASE, "Old_Photos")
        label = "Old_Photos"
    else:
        dest_dir = os.path.join(
            IMPORT_DEST_BASE,
            str(date.year), f"{date.month:02d}"
        )
        label = f"{date.year}/{date.month:02d}"

    return os.path.join(dest_dir, filename), label


def _get_destination_with_unknown(filepath: str, filename: str) -> tuple[str, str, bool]:
    """
    Enhanced destination logic that detects truly unknown dates.

    Uses the individual extraction functions to check if any real date was found.
    Falls back to Unknown_Date only when NO source provides a date.

    Returns:
        (full_dest_path, relative_dest_label, is_unknown_date)
    """
    from scanner import extract_exif_date, extract_video_date, extract_date_from_filename

    # Check each date source individually (same priority as get_best_date)
    exif_date = extract_exif_date(filepath)
    if exif_date:
        return _route_by_date(exif_date, filename), False

    video_date = extract_video_date(filepath)
    if video_date:
        return _route_by_date(video_date, filename), False

    fn_date = extract_date_from_filename(filename)
    if fn_date:
        return _route_by_date(fn_date, filename), False

    # Try filesystem dates — only use if they seem valid
    try:
        stat = os.stat(filepath)
        candidates = []
        birth = getattr(stat, 'st_birthtime', None)
        if birth:
            candidates.append(datetime.fromtimestamp(birth))
        if hasattr(stat, 'st_mtime'):
            candidates.append(datetime.fromtimestamp(stat.st_mtime))
        candidates.append(datetime.fromtimestamp(stat.st_ctime))

        now = datetime.now()
        valid = [d for d in candidates if d <= now]
        if valid:
            best = min(valid)
            return _route_by_date(best, filename), False
    except OSError:
        pass

    # Truly unknown — no date source worked
    dest_dir = os.path.join(IMPORT_DEST_BASE, "Unknown_Date")
    return (os.path.join(dest_dir, filename), "Unknown_Date"), True


def _route_by_date(date: datetime, filename: str) -> tuple[str, str]:
    """Route a file based on its date."""
    if date.year < IMPORT_OLD_PHOTOS_CUTOFF:
        dest_dir = os.path.join(IMPORT_DEST_BASE, "Old_Photos")
        label = "Old_Photos"
    else:
        dest_dir = os.path.join(
            IMPORT_DEST_BASE,
            str(date.year), f"{date.month:02d}"
        )
        label = f"{date.year}/{date.month:02d}"
    return os.path.join(dest_dir, filename), label


# ── Import Manager (main API) ───────────────────────────────────────────

class ImportManager:
    """
    Singleton import service.
    Designed for extension: pass different source_dir for Android/Camera/Family.
    """

    @staticmethod
    def scan(source_dir: str = IMPORT_SOURCE_DIR) -> dict:
        """
        Quick scan of the import folder.
        Returns file counts, sizes, and photo/video breakdown.
        Does NOT extract metadata — just counts by extension.
        """
        files = _collect_import_files(source_dir)

        photos = 0
        videos = 0
        total_size = 0

        for filepath in files:
            ext = os.path.splitext(filepath)[1].lower()
            try:
                total_size += os.path.getsize(filepath)
            except OSError:
                pass

            if ext in IMAGE_EXTENSIONS:
                photos += 1
            elif ext in VIDEO_EXTENSIONS:
                videos += 1

        return {
            "total_files": len(files),
            "photos": photos,
            "videos": videos,
            "total_size": total_size,
            "total_size_human": _format_size(total_size),
            "source_dir": source_dir,
        }

    @staticmethod
    def execute_preview(source_dir: str = IMPORT_SOURCE_DIR) -> ImportJob:
        """
        Starts a full preview in the background.
        Extracts dates for every file and computes destinations.
        """
        job = job_store.create()
        job.phase = "Initializing preview..."
        job.status = "running"
        job.started_at = datetime.now()
        
        thread = threading.Thread(target=ImportManager._run_preview, args=(job, source_dir), daemon=True)
        thread.start()
        
        return job

    @staticmethod
    def _run_preview(job: ImportJob, source_dir: str):
        """Background thread for executing the preview."""
        from database import SessionLocal
        db = SessionLocal()
        
        try:
            job.phase = "Finding files..."
            files = _collect_import_files(source_dir)
            job.total_files = len(files)
            
            destinations: dict[str, int] = {}
            unknown_count = 0

            for i, filepath in enumerate(files):
                filename = os.path.basename(filepath)
                (_, label), is_unknown = _get_destination_with_unknown(filepath, filename)

                if is_unknown:
                    unknown_count += 1

                destinations[label] = destinations.get(label, 0) + 1
                
                job.processed_files += 1
                job.progress = int(((i + 1) / len(files)) * 100)
                job.phase = f"Analyzing metadata... ({i + 1}/{len(files)})"

            # Sort destinations
            sorted_dests = []
            timeline_entries = []
            others = []
            
            for label, count in destinations.items():
                if label not in ("Old_Photos", "Unknown_Date"):
                    timeline_entries.append({"path": label, "count": count})
                else:
                    others.append({"path": label, "count": count})
                    
            # Sort timeline by path descending (newest first)
            timeline_entries.sort(key=lambda x: x["path"], reverse=True)

            # Others: Old_Photos first, then Unknown_Date
            others.sort(key=lambda x: (0 if x["path"] == "Old_Photos" else 1))

            sorted_dests = timeline_entries + others

            job.preview_destinations = {
                "destinations": sorted_dests,
                "total_files": len(files),
                "unknown_date": unknown_count,
            }
            
            job.status = "complete"
            job.phase = "Preview complete!"
            job.progress = 100
            
        except Exception as e:
            logger.error(f"Preview [{job.id}] failed: {e}", exc_info=True)
            job.status = "error"
            job.error_log.append(f"Fatal error: {str(e)}")
        finally:
            job.completed_at = datetime.now()
            db.close()

    @staticmethod
    def execute(
        source_dir: str = IMPORT_SOURCE_DIR,
        job_id: Optional[str] = None,
    ) -> ImportJob:
        """
        Start a background import job.
        Creates an ImportJob and runs the import in a daemon thread.
        Returns the job immediately (caller polls for progress).
        """
        job = job_store.create()
        if job_id:
            job.id = job_id

        job.started_at = datetime.now()
        job.status = "scanning"
        job.phase = "Scanning metadata..."

        thread = threading.Thread(
            target=_run_import,
            args=(source_dir, job),
            daemon=True,
        )
        thread.start()

        return job

    @staticmethod
    def execute_if_idle(source_dir: str = IMPORT_SOURCE_DIR) -> tuple[ImportJob, bool]:
        """
        Start an import unless a job is still running.
        Returns (job, started): the new job, or the running one with started=False.
        """
        with _start_lock:
            latest = job_store.get_latest()
            if latest and latest.status not in ("complete", "error"):
                return latest, False
            return ImportManager.execute(source_dir), True

    @staticmethod
    def get_job(job_id: str) -> Optional[ImportJob]:
        return job_store.get(job_id)

    @staticmethod
    def get_latest_job() -> Optional[ImportJob]:
        return job_store.get_latest()


# ── Background Import Execution ──────────────────────────────────────────

def _source_for_path(filepath: str) -> str:
    """Same source derivation as scanner.scan_directory (Vault/<Owner>/<Device>/...)."""
    parts = os.path.relpath(filepath, STORAGE_PATH).split(os.sep)
    if len(parts) >= 3 and parts[0] == "Vault":
        return SOURCE_MAPPING.get(parts[2], parts[2].lower())
    return "unknown"


def _index_imported_files(db: Session, imported: list[tuple[str, Optional[str]]]) -> int:
    """Index exactly the files this import moved (instead of rescanning the whole library).
    imported: [(final_path, sha256 or None)]. Returns the number of rows created."""
    from scanner import index_single_file

    indexed = 0
    for path, content_hash in imported:
        try:
            media = index_single_file(path, db)
        except Exception as e:
            logger.error(f"Indexing failed for {path}: {e}")
            continue
        if media is None:
            continue
        indexed += 1
        if not media.source:
            media.source = _source_for_path(path)
        if content_hash and not media.content_hash:
            media.content_hash = content_hash
    db.commit()
    return indexed


def _run_import(source_dir: str, job: ImportJob):
    """
    Background import worker.
    Phases:
        1. Scanning metadata     (0-15%)
        2. Organizing files      (15-25%)
        3. Moving files          (25-85%)
        4. Indexing new media    (85-100%)
    """
    db = None
    try:
        db = SessionLocal()
        files = _collect_import_files(source_dir)
        job.total_files = len(files)

        if not files:
            job.status = "complete"
            job.phase = "No files to import"
            job.progress = 100
            job.completed_at = datetime.now()
            return

        # ── Phase 1: Scanning metadata (0–15%) ──
        job.status = "scanning"
        job.phase = "Scanning metadata..."
        logger.info(f"Import [{job.id}]: Scanning {len(files)} files...")

        # Pre-compute all destinations
        file_plans = []  # [(filepath, dest_path, dest_label, is_unknown)]

        # Pre-fetch existing hashes and sizes for fast duplicate checking
        # Group existing files by size: library (v1), synced uploads, and the v2 Vault
        existing_sizes = {}
        for row in db.query(MediaFile.id, MediaFile.file_size, MediaFile.content_hash, MediaFile.path).all():
            fid, fsize, fchash, fpath = row
            if fsize not in existing_sizes:
                existing_sizes[fsize] = []
            existing_sizes[fsize].append({"id": fid, "content_hash": fchash, "path": fpath, "type": "media"})
            
        for row in db.query(SyncRecord.id, SyncRecord.file_size, SyncRecord.content_hash, SyncRecord.destination_path).all():
            fid, fsize, fchash, fpath = row
            if fsize not in existing_sizes:
                existing_sizes[fsize] = []
            existing_sizes[fsize].append({"id": fid, "content_hash": fchash, "path": fpath, "type": "sync"})

        for row in db.query(PhysicalObject.id, PhysicalObject.file_size, PhysicalObject.sha256, PhysicalObject.physical_path).all():
            fid, fsize, fchash, fpath = row
            if fsize not in existing_sizes:
                existing_sizes[fsize] = []
            existing_sizes[fsize].append({"id": fid, "content_hash": fchash, "path": os.path.join(STORAGE_PATH, fpath), "type": "v2"})

        for i, filepath in enumerate(files):
            filename = os.path.basename(filepath)
            (dest_path, label), is_unknown = _get_destination_with_unknown(filepath, filename)

            file_plans.append((filepath, dest_path, label, is_unknown))

            # Update progress (0–15%)
            job.progress = int((i + 1) / len(files) * 15)

        # ── Phase 2: Organizing files (15–25%) ──
        job.status = "importing"
        job.phase = "Organizing files..."
        job.progress = 15
        logger.info(f"Import [{job.id}]: Organizing {len(file_plans)} files...")

        # Identify duplicates and build move list
        moves = []  # [(src, dest, label, is_unknown, content_hash or None)]

        for filepath, dest_path, label, is_unknown in file_plans:
            filename = os.path.basename(filepath)
            incoming_hash = None

            # Duplicate check 1: Content Hash (Two-Stage Verification)
            try:
                fsize = os.path.getsize(filepath)
                if fsize in existing_sizes:
                    # Stage 2: Size matches, so check content hashes
                    candidates = existing_sizes[fsize]
                    is_dup = False
                    dup_path = ""
                    
                    for candidate in candidates:
                        cand_hash = candidate["content_hash"]
                        cand_path = candidate["path"]
                        
                        # If existing file doesn't have a hash, compute it dynamically to prevent race conditions
                        if not cand_hash:
                            if os.path.exists(cand_path):
                                cand_hash = compute_content_hash(cand_path)
                                candidate["content_hash"] = cand_hash
                                # Update DB on the spot
                                if candidate["type"] == "media":
                                    db.query(MediaFile).filter(MediaFile.id == candidate["id"]).update({"content_hash": cand_hash})
                                elif candidate["type"] == "sync":
                                    db.query(SyncRecord).filter(SyncRecord.id == candidate["id"]).update({"content_hash": cand_hash})
                                
                        if cand_hash:
                            if not incoming_hash:
                                incoming_hash = compute_content_hash(filepath)
                                
                            if incoming_hash == cand_hash:
                                is_dup = True
                                dup_path = cand_path
                                break
                                
                    if is_dup:
                        job.duplicates_skipped += 1
                        job.processed_files += 1
                        log_msg = f"Duplicate skipped: {filename} (Matches existing: {dup_path})"
                        job.error_log.append(log_msg)
                        logger.info(log_msg)
                        continue
            except OSError:
                fsize = None

            # Duplicate check 2: a file with the same name is already at the destination.
            # Same name is not same photo (camera counters wrap, devices share naming), so
            # compare content; a different file is imported under a _1, _2... name.
            if os.path.exists(dest_path):
                try:
                    same_size = fsize is not None and os.path.getsize(dest_path) == fsize
                    if same_size:
                        if not incoming_hash:
                            incoming_hash = compute_content_hash(filepath)
                        if incoming_hash and incoming_hash == compute_content_hash(dest_path):
                            job.duplicates_skipped += 1
                            job.processed_files += 1
                            log_msg = f"Duplicate skipped: {filename} (Matches existing: {dest_path})"
                            job.error_log.append(log_msg)
                            logger.info(log_msg)
                            continue
                except OSError:
                    pass

            moves.append((filepath, dest_path, label, is_unknown, incoming_hash))
            if is_unknown:
                job.unknown_date += 1

            # Later files in this same import are checked against this one too
            if fsize is not None:
                existing_sizes.setdefault(fsize, []).append(
                    {"id": None, "content_hash": incoming_hash, "path": filepath, "type": "incoming"}
                )

        # Keep the content hashes computed above for the next import
        db.commit()
        job.progress = 25

        # ── Phase 3: Moving files (25–85%) ──
        job.phase = "Moving files..."
        logger.info(f"Import [{job.id}]: Moving {len(moves)} files (skipping {job.duplicates_skipped} duplicates)...")

        imported_paths = []  # [(final_path, content_hash or None)]
        move_range = 60  # 25% → 85%
        for i, (src, dest, label, is_unknown, content_hash) in enumerate(moves):
            filename = os.path.basename(src)

            try:
                # Move the file; never overwrite: a taken name gets a _1, _2... suffix
                final_dest = claim_unique_path(src, os.path.dirname(dest), filename)
                imported_paths.append((final_dest, content_hash))
                job.imported += 1
                logger.debug(f"  MOVED: {filename} → {label}/")

            except Exception as e:
                job.errors += 1
                error_msg = f"{filename}: {str(e)}"
                job.error_log.append(error_msg)
                logger.error(f"  ERROR moving {filename}: {e}")

            job.processed_files += 1

            # Update progress (25–85%)
            if moves:
                job.progress = 25 + int((i + 1) / len(moves) * move_range)

        # ── Phase 4: Indexing new media (85–100%) ──
        job.phase = "Indexing new media..."
        job.progress = 85
        job.status = "indexing"
        logger.info(f"Import [{job.id}]: Indexing {len(imported_paths)} imported files...")

        try:
            indexed = _index_imported_files(db, imported_paths)
            logger.info(f"Import [{job.id}]: Indexed {indexed} files")
        except Exception as e:
            logger.error(f"Import [{job.id}]: Indexing error: {e}")
            job.error_log.append(f"Indexing: {str(e)}")

        # ── Done ──
        job.status = "complete"
        job.phase = "Complete"
        job.progress = 100
        job.completed_at = datetime.now()
        logger.info(
            f"Import [{job.id}]: Complete — "
            f"imported={job.imported}, dupes={job.duplicates_skipped}, "
            f"unknown={job.unknown_date}, errors={job.errors}"
        )

    except Exception as e:
        job.status = "error"
        job.phase = f"Error: {str(e)}"
        job.errors += 1
        job.error_log.append(str(e))
        job.completed_at = datetime.now()
        logger.error(f"Import [{job.id}]: Fatal error: {e}", exc_info=True)

    finally:
        if db:
            db.close()
