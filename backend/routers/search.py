"""
Synaps Search Router — Search APIs
"""
from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session
from sqlalchemy import or_
from database import get_db
from models import MediaFile

router = APIRouter(prefix="/api/search", tags=["search"])

LIKE_ESCAPE = "\\"


def like_pattern(q: str) -> str:
    """'%q%' with LIKE wildcards in q escaped, so 'IMG_1234' doesn't match 'IMGX1234'."""
    escaped = q.replace(LIKE_ESCAPE, LIKE_ESCAPE * 2).replace("%", LIKE_ESCAPE + "%").replace("_", LIKE_ESCAPE + "_")
    return f"%{escaped}%"


def _contains(column, pattern: str):
    # SQLite's LIKE is already case-insensitive for ASCII (its lower() is ASCII-only too), so
    # plain LIKE matches exactly what ilike() did without a lower() call per row and column.
    return column.like(pattern, escape=LIKE_ESCAPE)


@router.get("")
@router.get("/")
def search_media(
    q: str = Query(..., min_length=1, max_length=200),
    media_type: str = Query(None),
    page: int = Query(1, ge=1),
    per_page: int = Query(50, ge=1, le=200),
    db: Session = Depends(get_db),
):
    query = db.query(MediaFile)
    search_term = like_pattern(q)
    query = query.filter(
        or_(
            _contains(MediaFile.filename, search_term),
            _contains(MediaFile.directory, search_term),
            _contains(MediaFile.relative_path, search_term),
        )
    )
    if media_type:
        query = query.filter(MediaFile.media_type == media_type)
    total = query.count()
    offset = (page - 1) * per_page
    items = query.order_by(MediaFile.date_taken.desc()).offset(offset).limit(per_page).all()
    return {
        "query": q, "total": total, "page": page, "per_page": per_page,
        "results": [
            {
                "id": item.id, "filename": item.filename, "directory": item.directory,
                "media_type": item.media_type, "extension": item.extension,
                "file_size": item.file_size,
                "date_taken": item.date_taken.isoformat() if item.date_taken else None,
                "thumbnail_url": f"/api/media/thumbnail/{item.id}",
                "file_url": f"/api/media/file/{item.id}",
            }
            for item in items
        ],
    }


@router.get("/suggestions")
def search_suggestions(q: str = Query(..., min_length=1, max_length=200), db: Session = Depends(get_db)):
    search_term = like_pattern(q)
    files = db.query(MediaFile.filename).filter(_contains(MediaFile.filename, search_term)).distinct().limit(5).all()
    dirs = db.query(MediaFile.directory).filter(_contains(MediaFile.directory, search_term)).distinct().limit(5).all()
    return {"files": [f[0] for f in files], "directories": [d[0] for d in dirs]}
