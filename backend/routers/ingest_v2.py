"""
Synaps v2 Ingestion Router.
Provides high-performance, atomic streaming ingestion, client pre-check deduplication,
iPhone album sync, and virtual filesystem hierarchy queries.
"""
import os
import uuid
import hashlib
import logging
from datetime import datetime
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from pydantic import BaseModel
from sqlalchemy.orm import Session
from sqlalchemy import func

from database import get_db
from models_v2 import (
    Source, PhysicalObject, FilesystemNode, LogicalItem,
    Album, AlbumItem, MediaMetadata
)
from storage_engine import (
    store_staged_file, create_hardlink_mirror, get_staging_root,
    get_storage_path, init_storage_directories
)
from node_manager import get_or_create_node_path
from scanner import classify_media, get_best_date

logger = logging.getLogger("synaps.ingest_v2")

router = APIRouter(prefix="/api/v2", tags=["ingest_v2"])

CHUNK_SIZE = 256 * 1024  # 256 KB chunks to protect NAS RAM


# ── Pydantic Request Models ───────────────────────────────────────────────

class SourceRegistration(BaseModel):
    id: str
    friendly_name: str
    platform: str  # "macOS", "Windows", "iOS"
    volume_identifier: Optional[str] = None


class CheckFileItem(BaseModel):
    original_path: str
    original_filename: str
    file_size: int
    source_location: str
    source_modified_at: Optional[str] = None
    client_sha256: str
    is_favorite: Optional[bool] = False


class CheckBatchRequest(BaseModel):
    source: SourceRegistration
    files: List[CheckFileItem]


class AlbumSyncRequest(BaseModel):
    source_id: str
    album_name: str
    original_paths: List[str]


# ── 1. Client Pre-Check (Fast Deduplication) ──────────────────────────────

@router.post("/ingest/check")
def check_ingest_batch(req: CheckBatchRequest, db: Session = Depends(get_db)):
    """
    Checks incoming batch against existing physical objects on the NAS.
    If SHA-256 exists, links provenance instantly with zero network transfer.
    """
    init_storage_directories()

    # 1. Ensure source is registered/updated
    source = db.query(Source).filter(Source.id == req.source.id).first()
    if not source:
        source = Source(
            id=req.source.id,
            friendly_name=req.source.friendly_name,
            platform=req.source.platform,
            volume_identifier=req.source.volume_identifier,
        )
        db.add(source)
    else:
        source.friendly_name = req.source.friendly_name
        source.last_seen_at = datetime.now()
    db.flush()

    results = []
    need_upload_count = 0
    dedup_count = 0

    for item in req.files:
        sha = item.client_sha256.lower()

        # Check if physical object already exists
        phys_obj = db.query(PhysicalObject).filter(PhysicalObject.sha256 == sha).first()

        if phys_obj:
            # Physical file is already on the NAS!
            # Check if this exact logical provenance already exists
            existing_logical = (
                db.query(LogicalItem)
                .filter(
                    LogicalItem.source_id == source.id,
                    LogicalItem.original_path == item.original_path
                )
                .first()
            )

            if not existing_logical:
                # Build node hierarchy
                node = get_or_create_node_path(
                    db=db,
                    source_id=source.id,
                    original_path=item.original_path,
                    platform=source.platform,
                    physical_object_id=phys_obj.id
                )

                # Parse timestamps
                mod_dt = None
                if item.source_modified_at:
                    try:
                        mod_dt = datetime.fromisoformat(item.source_modified_at)
                    except ValueError:
                        pass

                # Create logical item
                logical = LogicalItem(
                    physical_object_id=phys_obj.id,
                    source_id=source.id,
                    node_id=node.id,
                    original_path=item.original_path,
                    original_filename=item.original_filename,
                    source_location=item.source_location,
                    source_modified_at=mod_dt,
                )
                db.add(logical)
                phys_obj.reference_count = (phys_obj.reference_count or 0) + 1

                # If item is marked favorite, update metadata if not already favorite
                if item.is_favorite and phys_obj.metadata_record:
                    phys_obj.metadata_record.is_favorite = True

                # Create hardlink mirror on NAS disk
                phys_full = os.path.join(get_storage_path(), phys_obj.physical_path)
                create_hardlink_mirror(phys_full, source.friendly_name, item.original_path, source.platform)

            dedup_count += 1
            results.append({
                "original_path": item.original_path,
                "status": "dedup_linked",
                "physical_object_id": phys_obj.id,
            })
        else:
            need_upload_count += 1
            results.append({
                "original_path": item.original_path,
                "status": "need_upload",
                "physical_object_id": None,
            })

    db.commit()

    return {
        "source_id": source.id,
        "total_checked": len(req.files),
        "need_upload": need_upload_count,
        "dedup_linked": dedup_count,
        "results": results,
    }


# ── 2. Streaming Chunked Upload Receiver ─────────────────────────────────

@router.post("/ingest/upload")
async def upload_file_v2(
    source_id: str = Form(...),
    original_path: str = Form(...),
    original_filename: str = Form(...),
    source_location: str = Form(...),
    client_sha256: str = Form(...),
    source_created_at: Optional[str] = Form(None),
    source_modified_at: Optional[str] = Form(None),
    is_favorite: bool = Form(False),
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
):
    """
    Receives a new physical file via streaming I/O.
    Validates SHA-256 on the fly, stores into canonical Vault_v2,
    creates hardlink mirror, and records relational provenance.
    """
    init_storage_directories()
    client_sha = client_sha256.lower().strip()

    # Create temporary file in staging directory
    temp_id = str(uuid.uuid4())
    temp_path = os.path.join(get_staging_root(), f"{temp_id}.upload")

    hasher = hashlib.sha256()
    total_bytes = 0

    try:
        with open(temp_path, "wb") as f_out:
            while True:
                chunk = await file.read(CHUNK_SIZE)
                if not chunk:
                    break
                hasher.update(chunk)
                f_out.write(chunk)
                total_bytes += len(chunk)
    except Exception as e:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        logger.error(f"Stream upload failed: {e}")
        raise HTTPException(status_code=500, detail=f"Upload stream error: {e}")

    computed_sha = hasher.hexdigest().lower()

    # Verify SHA-256 integrity immediately
    if computed_sha != client_sha:
        if os.path.exists(temp_path):
            os.remove(temp_path)
        raise HTTPException(
            status_code=400,
            detail=f"SHA-256 mismatch: client={client_sha}, computed={computed_sha}"
        )

    # Get or auto-register source
    source = db.query(Source).filter(Source.id == source_id).first()
    if not source:
        platform = "macOS"
        if "win" in source_id.lower():
            platform = "Windows"
        elif "iphone" in source_id.lower() or "ios" in source_id.lower():
            platform = "iOS"

        source = Source(
            id=source_id,
            friendly_name=source_id,
            platform=platform,
        )
        db.add(source)
        db.flush()

    fav_bool = False
    if isinstance(is_favorite, bool):
        fav_bool = is_favorite
    elif isinstance(is_favorite, str):
        fav_bool = is_favorite.lower() in ("true", "1", "yes")

    # Check if physical object already exists (e.g. concurrent upload)
    phys_obj = db.query(PhysicalObject).filter(PhysicalObject.sha256 == computed_sha).first()

    ext = os.path.splitext(original_filename)[1].lower()

    if not phys_obj:
        # Extract media metadata from temp file before moving
        classification = classify_media(ext, original_filename)
        capture_date = get_best_date(temp_path, original_filename)

        # Move to canonical vault
        canonical_rel, canonical_full, file_size = store_staged_file(
            temp_file_path=temp_path,
            capture_date=capture_date,
            computed_sha256=computed_sha,
            original_filename=original_filename
        )

        phys_obj = PhysicalObject(
            sha256=computed_sha,
            file_size=file_size,
            physical_path=canonical_rel,
            mime_type=file.content_type or "application/octet-stream",
            reference_count=1,
        )
        db.add(phys_obj)
        db.flush()

        metadata = MediaMetadata(
            physical_object_id=phys_obj.id,
            capture_date=capture_date,
            media_type=classification["media_type"],
            is_screenshot=classification["is_screenshot"],
            is_screen_recording=classification["is_screen_recording"],
            is_favorite=fav_bool,
        )
        db.add(metadata)

        # Enqueue silent background thumbnail generation immediately
        try:
            from thumbnails import enqueue_thumbnail
            enqueue_thumbnail(canonical_full)
        except Exception as e:
            logger.debug(f"Failed to enqueue thumbnail on ingest: {e}")
    else:
        # File already exists canonically
        if os.path.exists(temp_path):
            os.remove(temp_path)
        phys_obj.reference_count = (phys_obj.reference_count or 0) + 1
        if fav_bool and phys_obj.metadata_record:
            phys_obj.metadata_record.is_favorite = True

        # Ensure existing file has thumbnail generated in background
        try:
            from thumbnails import enqueue_thumbnail
            full_canon = os.path.join(get_storage_path(), phys_obj.physical_path)
            enqueue_thumbnail(full_canon)
        except Exception:
            pass

    # Build node hierarchy
    node = get_or_create_node_path(
        db=db,
        source_id=source.id,
        original_path=original_path,
        platform=source.platform,
        physical_object_id=phys_obj.id
    )

    # Parse source timestamps
    src_c = None
    if isinstance(source_created_at, str) and source_created_at.strip():
        try:
            src_c = datetime.fromisoformat(source_created_at.strip())
        except (ValueError, TypeError):
            pass

    src_m = None
    if isinstance(source_modified_at, str) and source_modified_at.strip():
        try:
            src_m = datetime.fromisoformat(source_modified_at.strip())
        except (ValueError, TypeError):
            pass

    # Check for existing logical item
    logical = (
        db.query(LogicalItem)
        .filter(LogicalItem.source_id == source.id, LogicalItem.original_path == original_path)
        .first()
    )

    if not logical:
        logical = LogicalItem(
            physical_object_id=phys_obj.id,
            source_id=source.id,
            node_id=node.id,
            original_path=original_path,
            original_filename=original_filename,
            source_location=source_location,
            source_created_at=src_c,
            source_modified_at=src_m,
        )
        db.add(logical)
    else:
        # Update pointer if modified
        logical.physical_object_id = phys_obj.id
        logical.source_modified_at = src_m

    # Create hardlink mirror
    phys_full_path = os.path.join(get_storage_path(), phys_obj.physical_path)
    mirror_path = create_hardlink_mirror(phys_full_path, source.friendly_name, original_path, source.platform)

    db.commit()

    return {
        "status": "success",
        "physical_object_id": phys_obj.id,
        "logical_item_id": logical.id,
        "canonical_path": phys_obj.physical_path,
        "mirror_path": mirror_path,
        "sha256": phys_obj.sha256,
    }


# ── 3. iPhone Album Sync ──────────────────────────────────────────────────

@router.post("/ingest/albums")
def sync_albums(req: AlbumSyncRequest, db: Session = Depends(get_db)):
    """
    Synchronizes album memberships (e.g. from iPhone Photos app).
    """
    source = db.query(Source).filter(Source.id == req.source_id).first()
    if not source:
        raise HTTPException(status_code=404, detail="Source not found")

    album = (
        db.query(Album)
        .filter(Album.source_id == req.source_id, Album.name == req.album_name)
        .first()
    )

    if not album:
        album = Album(name=req.album_name, source_id=req.source_id)
        db.add(album)
        db.flush()

    linked_count = 0
    for path in req.original_paths:
        logical = (
            db.query(LogicalItem)
            .filter(LogicalItem.source_id == req.source_id, LogicalItem.original_path == path)
            .first()
        )
        if logical:
            # Check if membership exists
            existing_link = (
                db.query(AlbumItem)
                .filter(AlbumItem.album_id == album.id, AlbumItem.logical_item_id == logical.id)
                .first()
            )
            if not existing_link:
                item = AlbumItem(album_id=album.id, logical_item_id=logical.id)
                db.add(item)
                linked_count += 1

    db.commit()
    return {
        "album_id": album.id,
        "album_name": album.name,
        "newly_linked_items": linked_count,
    }


# ── 4. Virtual Filesystem Navigation APIs ─────────────────────────────────

@router.get("/sources")
def list_sources(db: Session = Depends(get_db)):
    """List all registered device sources with item counts."""
    sources = db.query(Source).all()
    out = []
    for s in sources:
        count = db.query(LogicalItem).filter(LogicalItem.source_id == s.id).count()
        out.append({
            **s.to_dict(),
            "total_items": count,
        })
    return {"sources": out}


@router.get("/sources/{source_id}/tree")
def browse_source_tree(
    source_id: str,
    parent_id: Optional[int] = None,
    db: Session = Depends(get_db)
):
    """
    Instantly browse a directory node in a device's virtual filesystem.
    Returns immediate child folders and files with zero disk scans.
    """
    source = db.query(Source).filter(Source.id == source_id).first()
    if not source:
        raise HTTPException(status_code=404, detail="Source not found")

    # Query immediate child nodes
    query = (
        db.query(FilesystemNode)
        .filter(FilesystemNode.source_id == source_id, FilesystemNode.parent_id == parent_id)
        .order_by(FilesystemNode.is_directory.desc(), FilesystemNode.name.asc())
    )
    nodes = query.all()

    folders = []
    files = []

    for node in nodes:
        if node.is_directory:
            # Count immediate children
            child_count = (
                db.query(func.count(FilesystemNode.id))
                .filter(FilesystemNode.parent_id == node.id)
                .scalar()
            )
            folders.append({
                "id": node.id,
                "name": node.name,
                "type": "folder",
                "children_count": child_count,
            })
        else:
            logical = node.logical_item
            phys = node.physical_object
            meta = phys.metadata_record if phys else None

            files.append({
                "id": node.id,
                "name": node.name,
                "type": "file",
                "physical_object_id": node.physical_object_id,
                "logical_item_id": logical.id if logical else None,
                "file_size": phys.file_size if phys else 0,
                "media_type": meta.media_type if meta else "document",
                "is_favorite": meta.is_favorite if meta else False,
                "capture_date": meta.capture_date.isoformat() if meta and meta.capture_date else None,
                "sha256": phys.sha256 if phys else None,
                "original_path": logical.original_path if logical else None,
            })

    # Build breadcrumbs
    breadcrumbs = [{"id": None, "name": source.friendly_name}]
    curr = db.query(FilesystemNode).filter(FilesystemNode.id == parent_id).first() if parent_id else None
    chain = []
    while curr:
        chain.append({"id": curr.id, "name": curr.name})
        curr = db.query(FilesystemNode).filter(FilesystemNode.id == curr.parent_id).first() if curr.parent_id else None
    breadcrumbs.extend(reversed(chain))

    return {
        "source": source.to_dict(),
        "parent_id": parent_id,
        "breadcrumbs": breadcrumbs,
        "folders": folders,
        "files": files,
        "total_folders": len(folders),
        "total_files": len(files),
    }


@router.get("/albums")
def list_albums(db: Session = Depends(get_db)):
    """List all synced albums with item counts and cover photos."""
    albums = db.query(Album).order_by(Album.name.asc()).all()
    out = []
    for alb in albums:
        # Get first item for cover thumbnail
        first_item = (
            db.query(AlbumItem)
            .filter(AlbumItem.album_id == alb.id)
            .first()
        )
        cover_phys_id = None
        if first_item and first_item.logical_item:
            cover_phys_id = first_item.logical_item.physical_object_id

        out.append({
            "id": alb.id,
            "name": alb.name,
            "source_id": alb.source_id,
            "item_count": len(alb.items),
            "cover_physical_id": cover_phys_id,
            "created_at": alb.created_at.isoformat() if alb.created_at else None,
        })
    return {"albums": out}


@router.get("/albums/{album_id}")
def get_album_items(album_id: str, db: Session = Depends(get_db)):
    """Get all items in a specific album."""
    album = db.query(Album).filter(Album.id == album_id).first()
    if not album:
        raise HTTPException(status_code=404, detail="Album not found")

    items = []
    for link in album.items:
        logical = link.logical_item
        if logical and logical.physical_object:
            phys = logical.physical_object
            meta = phys.metadata_record
            items.append({
                "logical_id": logical.id,
                "physical_object_id": phys.id,
                "filename": logical.original_filename,
                "original_path": logical.original_path,
                "file_size": phys.file_size,
                "media_type": meta.media_type if meta else "image",
                "is_favorite": meta.is_favorite if meta else False,
                "capture_date": meta.capture_date.isoformat() if meta and meta.capture_date else None,
            })

    return {
        "album": album.to_dict(),
        "items": items,
        "total_items": len(items),
    }
