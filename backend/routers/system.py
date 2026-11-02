"""
Synaps System Router: the data behind the web app's stats dashboard.

Live and historical system metrics (system_metrics.py), backup activity per day and per
device, recent uploads and storage use. Backup numbers come from the v2 vault tables
(logical_items, physical_objects), which every Mac and iPhone upload goes through.

Times: metric timestamps are UTC unix seconds; datetimes are ISO 8601 in UTC ("...Z").
Per-day backup counts use the NAS's local calendar day.
"""
import os
import socket
import time
from datetime import date, datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import String, bindparam, case, cast, func
from sqlalchemy.orm import Session

import config
import system_metrics
from database import engine, get_db
from models_v2 import LogicalItem, PhysicalObject, Source
from routers.settings import _cached_dir_size
from routers.trash import STORAGE_TRASH_DIR
from system_metrics import SystemMetricsHourly, SystemMetricsMinute

router = APIRouter(prefix="/api/system", tags=["system"])

HISTORY_RANGES = {
    # range: (seconds covered, table, resolution in seconds)
    "1h": (3600, SystemMetricsMinute, 60),
    "24h": (86400, SystemMetricsMinute, 60),
    "7d": (7 * 86400, SystemMetricsHourly, 3600),
    "30d": (30 * 86400, SystemMetricsHourly, 3600),
}
HISTORY_FIELDS = ("cpu_percent", "load_1", "mem_used", "mem_total", "swap_used", "temp_c",
                  "net_rx_bps", "net_tx_bps", "disk_used", "disk_total")
HOURLY_ONLY_FIELDS = ("cpu_max", "temp_max")


def _iso_utc(value: Optional[datetime]) -> Optional[str]:
    """Naive UTC datetime from the database -> ISO 8601 with a Z."""
    return value.replace(microsecond=0).isoformat() + "Z" if value else None


def _database_bytes() -> Optional[int]:
    path = engine.url.database
    if not path:
        return None
    total = 0
    for suffix in ("", "-wal"):
        try:
            total += os.path.getsize(path + suffix)
        except OSError:
            if not suffix:
                return None
    return total


def _scan_running() -> Optional[bool]:
    try:
        import main
        return main._scan_lock.locked()
    except Exception:
        return None


def _thumbnail_queue() -> Optional[int]:
    try:
        from thumbnails import _queue
        return _queue.qsize()
    except Exception:
        return None


@router.get("/now")
def system_now():
    """Current values for every card. Cheap: no database queries beyond the file size."""
    sample = system_metrics.current_snapshot(max_age=2 * max(config.METRICS_INTERVAL_SECONDS, 1))
    disk_total, disk_used = sample["disk_total"], sample["disk_used"]
    load = system_metrics.read_loadavg()
    memory = system_metrics.read_memory()
    return {
        "hostname": socket.gethostname().split(".")[0],
        "sampled_at": sample["ts"],
        "sampler_running": config.METRICS_INTERVAL_SECONDS > 0,
        "cpu": {
            "percent": sample["cpu_percent"],
            "cores": os.cpu_count(),
            "load": list(load) if load else None,
        },
        "memory": {
            "total": memory["total"] if memory else None,
            "used": memory["used"] if memory else None,
            "available": memory["available"] if memory else None,
            "swap_total": memory["swap_total"] if memory else None,
            "swap_used": memory["swap_used"] if memory else None,
        },
        "temperature_c": sample["temp_c"],
        "network": {"rx_bps": sample["net_rx_bps"], "tx_bps": sample["net_tx_bps"]},
        "disk": {
            "total": disk_total,
            "used": disk_used,
            "free": disk_total - disk_used if disk_total is not None and disk_used is not None else None,
            "percent": round(100 * disk_used / disk_total, 1) if disk_total else None,
        },
        "uptime": {
            "system_seconds": system_metrics.read_uptime(),
            "backend_seconds": round(time.time() - system_metrics.PROCESS_STARTED_AT),
        },
        "services": {
            "thumbnail_queue": _thumbnail_queue(),
            "scan_running": _scan_running(),
            "database_bytes": _database_bytes(),
            "api_token_enabled": bool(config.API_TOKEN),
        },
    }


@router.get("/history")
def system_history(
    range: Literal["1h", "24h", "7d", "30d"] = Query("24h"),
    db: Session = Depends(get_db),
):
    """Time series for the charts: minute samples for 1h/24h, hourly averages for 7d/30d."""
    seconds, table, resolution = HISTORY_RANGES[range]
    since = int(time.time()) - seconds
    fields = HISTORY_FIELDS + (HOURLY_ONLY_FIELDS if table is SystemMetricsHourly else ())
    rows = db.query(table).filter(table.ts >= since).order_by(table.ts).all()
    first = [
        db.query(func.min(t.ts)).scalar() for t in (SystemMetricsMinute, SystemMetricsHourly)
    ]
    first = [t for t in first if t is not None]
    return {
        "range": range,
        "resolution_seconds": resolution,
        # When collection began, so the page can say "collecting data since ..." honestly
        "collecting_since": min(first) if first else None,
        "points": [{"t": row.ts, **{f: getattr(row, f) for f in fields}} for row in rows],
    }


def _local_day_start_utc(day: date) -> datetime:
    """Local midnight of `day` as a naive UTC datetime (how the database stores times)."""
    return datetime.combine(day, datetime.min.time()).astimezone(timezone.utc).replace(tzinfo=None)


@router.get("/backups")
def backup_history(days: int = Query(30, ge=1, le=90), db: Session = Depends(get_db)):
    """Files and bytes backed up per local day, overall and per device. `files`/`bytes` count
    every upload, including ones the NAS already had (linked without storing a second copy);
    `new_files`/`new_bytes` count only what added new data to the vault."""
    today = date.today()
    start = today - timedelta(days=days - 1)
    # Compared as stored text without a fraction, so it sorts before both stored formats (see activity())
    since = bindparam("since", _local_day_start_utc(start).strftime("%Y-%m-%d %H:%M:%S"), type_=String)

    day_of = func.date(LogicalItem.imported_at, "localtime")
    uploads = (
        db.query(day_of, LogicalItem.source_id, func.count(LogicalItem.id), func.sum(PhysicalObject.file_size))
        .join(PhysicalObject, PhysicalObject.id == LogicalItem.physical_object_id)
        .filter(LogicalItem.imported_at >= since)
        .group_by(day_of, LogicalItem.source_id)
        .all()
    )
    new_day = func.date(PhysicalObject.created_at, "localtime")
    new_data = (
        db.query(new_day, func.count(PhysicalObject.id), func.sum(PhysicalObject.file_size))
        .filter(PhysicalObject.created_at >= since)
        .group_by(new_day)
        .all()
    )

    series = {}
    for offset in range(days):
        key = (start + timedelta(days=offset)).isoformat()
        series[key] = {"date": key, "files": 0, "bytes": 0, "new_files": 0, "new_bytes": 0, "by_device": {}}
    for day, source_id, count, size in uploads:
        if day in series:
            entry = series[day]
            entry["files"] += count
            entry["bytes"] += size or 0
            entry["by_device"][source_id] = {"files": count, "bytes": size or 0}
    for day, count, size in new_data:
        if day in series:
            series[day]["new_files"] = count
            series[day]["new_bytes"] = size or 0

    names = {s.id: s.friendly_name for s in db.query(Source).all()}
    return {"days": days, "start": start.isoformat(), "devices": names, "series": list(series.values())}


@router.get("/devices")
def devices(db: Session = Depends(get_db)):
    """Every device that has registered with the NAS, with its last backup and totals."""
    totals = {
        source_id: (count, size, last)
        for source_id, count, size, last in (
            db.query(
                LogicalItem.source_id,
                func.count(LogicalItem.id),
                func.sum(PhysicalObject.file_size),
                func.max(LogicalItem.imported_at),
            )
            .join(PhysicalObject, PhysicalObject.id == LogicalItem.physical_object_id)
            .group_by(LogicalItem.source_id)
            .all()
        )
    }
    result = []
    for source in db.query(Source).all():
        count, size, last = totals.get(source.id, (0, 0, None))
        result.append({
            "id": source.id,
            "name": source.friendly_name,
            "platform": source.platform,
            "files": count,
            "bytes": size or 0,
            "last_backup_at": _iso_utc(last),
            "last_contact_at": _iso_utc(source.last_seen_at),
            "registered_at": _iso_utc(source.created_at),
        })
    result.sort(key=lambda d: d["last_backup_at"] or "", reverse=True)
    return {"devices": result}


@router.get("/activity")
def activity(
    limit: int = Query(50, ge=1, le=200),
    before: Optional[str] = Query(None, description="Cursor from the previous page's next_before"),
    db: Session = Depends(get_db),
):
    """Most recent uploads, newest first, paged by cursor (stable while new uploads arrive).

    SQLite stores these datetimes as text in two formats (its CURRENT_TIMESTAMP default writes
    no fraction, SQLAlchemy writes microseconds), and ORDER BY sorts that text. So the cursor
    carries the stored text itself and is compared as text, exactly as ORDER BY sorts it."""
    stored_at = cast(LogicalItem.imported_at, String)
    query = (
        db.query(LogicalItem, stored_at, PhysicalObject.file_size, PhysicalObject.mime_type, Source.friendly_name)
        .join(PhysicalObject, PhysicalObject.id == LogicalItem.physical_object_id)
        .outerjoin(Source, Source.id == LogicalItem.source_id)
    )
    if before:
        stamp, sep, item_id = before.partition("|")
        try:
            datetime.fromisoformat(stamp)
        except ValueError:
            stamp = None
        if not sep or not stamp or not item_id:
            raise HTTPException(status_code=400, detail="Invalid cursor")
        stamp_text = bindparam("before_at", stamp, type_=String)
        query = query.filter(
            (LogicalItem.imported_at < stamp_text)
            | ((LogicalItem.imported_at == stamp_text) & (LogicalItem.id < item_id))
        )
    rows = query.order_by(LogicalItem.imported_at.desc(), LogicalItem.id.desc()).limit(limit + 1).all()
    has_more = len(rows) > limit
    rows = rows[:limit]
    items = [
        {
            "id": item.id,
            "imported_at": _iso_utc(item.imported_at),
            "device_id": item.source_id,
            "device_name": name,
            "filename": item.original_filename,
            "location": item.source_location,
            "bytes": size or 0,
            "mime_type": mime,
        }
        for item, _, size, mime, name in rows
    ]
    next_before = None
    if has_more and rows:
        last, last_stored_at = rows[-1][0], rows[-1][1]
        next_before = f"{last_stored_at}|{last.id}"
    return {"items": items, "next_before": next_before}


@router.get("/storage")
def storage(db: Session = Depends(get_db)):
    """What the vault holds, by kind, and how much space deduplication saves."""
    kind = case(
        (PhysicalObject.mime_type.like("image/%"), "photos"),
        (PhysicalObject.mime_type.like("video/%"), "videos"),
        else_="other",
    )
    by_kind = {k: {"files": 0, "bytes": 0} for k in ("photos", "videos", "other")}
    for name, count, size in db.query(kind, func.count(PhysicalObject.id), func.sum(PhysicalObject.file_size)).group_by(kind):
        by_kind[name] = {"files": count, "bytes": size or 0}
    stored_bytes = sum(k["bytes"] for k in by_kind.values())

    uploaded_files, uploaded_bytes = (
        db.query(func.count(LogicalItem.id), func.sum(PhysicalObject.file_size))
        .join(PhysicalObject, PhysicalObject.id == LogicalItem.physical_object_id)
        .one()
    )
    uploaded_bytes = uploaded_bytes or 0

    trash_parts = [_cached_dir_size(d) for d in (config.TRASH_DIR, STORAGE_TRASH_DIR)]
    disk = system_metrics.read_disk()
    return {
        "vault": {
            "by_kind": by_kind,
            "stored_files": sum(k["files"] for k in by_kind.values()),
            "stored_bytes": stored_bytes,
            # Every device's uploads counted separately, as if each file were stored once per upload
            "uploaded_files": uploaded_files,
            "uploaded_bytes": uploaded_bytes,
            "dedup_saved_bytes": max(0, uploaded_bytes - stored_bytes),
        },
        # None until the background size walk finishes (see routers/settings.py)
        "thumbnail_cache_bytes": _cached_dir_size(config.THUMBNAIL_DIR),
        "trash_bytes": None if None in trash_parts else sum(trash_parts),
        "disk": {"total": disk[0], "used": disk[1], "free": disk[2]} if disk else None,
    }
