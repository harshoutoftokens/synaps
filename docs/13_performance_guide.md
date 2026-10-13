# 13 — Performance Guide

Synaps is designed to run on a low-power NAS (Core2Duo, ~2GB RAM). This guide explains current bottlenecks, what's already optimized, and what you can improve.

---

## The Hardware Context

A typical old NAS or repurposed PC used for this project:
- **CPU**: Intel Core2Duo (2 cores, 1.6–2.4GHz, no AVX)
- **RAM**: 1–4GB
- **Storage**: HDD (spinning disk, ~100MB/s seq, ~1ms–10ms seek)
- **Network**: 100Mbps or 1Gbps local ethernet

This is similar in power to a budget Android phone from 2016.

---

## Current Bottlenecks (Biggest to Smallest)

### 1. Thumbnail Generation — BIGGEST

**Why it's slow**: Each thumbnail requires:
- Reading the original file (disk I/O, 4–50MB per file)
- Decoding the image format (CPU, especially for HEIC)
- Scaling the image (CPU)
- Encoding to WebP (CPU)
- Writing the thumbnail to disk

On a Core2Duo with an HDD, generating one HEIC thumbnail takes 1–5 seconds. For 1,000 photos, that's 16–83 minutes of thumbnail generation time.

**What's already done**:
- Lazy generation: thumbnails only generate when first requested
- Disk cache: generated once, served forever
- Single-file processing: no parallelism (prevents memory overload)

**What you can still improve**:
- Pre-generate thumbnails in a background queue during off-peak hours
- Use a faster image format for the original files (if you control the source)
- Limit THUMBNAIL_QUALITY to 60–65 (down from 75) for faster encoding

### 2. Scanner on Large Libraries — MEDIUM

**Why it's slow**: For each file:
- `os.stat()` — disk I/O
- `open()` + read 64KB — disk I/O
- `exifread.process_file()` — CPU + disk I/O (reads EXIF metadata)
- One DB insert per 100 files — minimal

For 10,000 photos, a full scan takes 5–30 minutes on spinning HDD.

**What's already done**:
- In-memory set for existing path lookup (avoids per-file DB query)
- Batch commits (100 files per transaction)
- `stop_tag` in exifread (stops parsing early)
- Only scans whitelisted directories

**What you can still improve**:
- Skip `compute_file_hash()` on initial scan (move to background task)
- Use `os.scandir()` instead of `os.walk()` for slightly better performance
- Add a `last_modified` check — only re-scan files whose mtime changed

### 3. Database Queries on Large Libraries — LOW-MEDIUM

For a library of 50,000 files, the timeline query fetches 80 items sorted by `date_taken`. With the index on `date_taken`, this should take < 10ms.

**Potential issue**: Year/month filtering uses `func.strftime()`:
```python
func.strftime("%Y", MediaFile.date_taken) == str(year)
```

SQLite cannot use the `date_taken` index for this expression. For 50,000 rows, it scans the whole table — could take 50–200ms on slow hardware.

**Fix**: Use range-based filtering instead:
```python
from datetime import datetime
year_start = datetime(year, 1, 1)
year_end = datetime(year + 1, 1, 1)
query.filter(MediaFile.date_taken >= year_start, MediaFile.date_taken < year_end)
```

This uses the index. Can be 10–100x faster on large tables.

### 4. Serving Thumbnails via Python — LOW

Each thumbnail request goes through:
- Next.js proxy → HTTP overhead
- FastAPI → Python overhead
- `os.path.exists()` check
- `FileResponse` → reads file, sets headers, streams

For 80 thumbnails on a page, that's 80 parallel HTTP requests through Python.

**Fix**: Serve thumbnails directly from nginx:
```nginx
location /thumbnails/ {
    alias /path/to/backend/thumbnails/;
    expires 30d;
}
```

Nginx serves static files 10–50x faster than Python/FastAPI.

---

## What's Already Optimized

### Frontend

| Optimization | Where | Benefit |
|-------------|-------|---------|
| `loading="lazy"` on `<img>` | MediaGrid.tsx | Only loads images near viewport |
| Pagination (80 items/page) | page.tsx | Never loads all 10k photos at once |
| IntersectionObserver for infinite scroll | page.tsx | Triggers load at natural scroll point |
| Dedup tracking with `Set` | page.tsx | O(1) duplicate checking |
| Skeleton loading | MediaThumbnail | Smooth perceived performance |
| Client-side navigation (no full reload) | Next.js | Instant page transitions |
| Next.js production build | package.json | Minified JS, less parse time |

### Backend

| Optimization | Where | Benefit |
|-------------|-------|---------|
| Background scan thread | main.py | API available immediately |
| Batch commits (100 items) | scanner.py | Less DB overhead |
| Memory-based path lookup | scanner.py | No per-file DB query |
| Lazy thumbnail generation | thumbnails.py | Only generate when needed |
| Disk-cached thumbnails | thumbnails.py | Generate once, serve forever |
| `stop_tag` in exifread | scanner.py | Faster EXIF reading |
| SQLite indexes on key columns | models.py | Fast queries |

---

## Specific Optimizations for Weak NAS Hardware

### 1. Reduce THUMBNAIL_SIZE

Current: `(320, 320)`. At this size, your media grid renders 160–200px images. The extra resolution isn't visible.

```python
# config.py
THUMBNAIL_SIZE = (240, 240)   # Faster generation, smaller files
THUMBNAIL_QUALITY = 65        # Lower quality, faster encoding
```

This would reduce thumbnail generation time by ~30% and thumbnail file sizes by ~40%.

### 2. Use Single Worker in uvicorn

Already done in the systemd unit installed by `./synaps install` (`python main.py` runs one uvicorn worker):
```bash
uvicorn main:app --workers 1
```

With 2 workers, each worker loads the Python interpreter separately — doubles RAM usage. On 2GB RAM, a single worker is more stable.

### 3. Disable exifread for Non-Photo Files

The scanner currently tries EXIF on all supported extensions. For videos, EXIF reading is fast (skipped because of the extension check), but for HEIC files it's slow.

Already optimized in `extract_exif_date()` — only attempts EXIF on specific extensions. This is correct.

### 4. Add Memory Limits to Python

```bash
# Limit backend memory to 512MB
# In systemd service file:
MemoryMax=512M
```

If the scanner causes a memory spike, this prevents it from killing the system.

### 5. Use SQLite WAL Mode

WAL (Write-Ahead Logging) allows simultaneous reads and writes:

```python
# In database.py, after creating engine:
with engine.connect() as conn:
    conn.execute(text("PRAGMA journal_mode=WAL"))
    conn.execute(text("PRAGMA synchronous=NORMAL"))  # Faster, slightly less safe
    conn.execute(text("PRAGMA cache_size=-64000"))   # 64MB cache
```

This significantly improves performance when the scanner (writing) and API (reading) run simultaneously.

### 6. Add SQLite Connection Pool Settings

```python
engine = create_engine(
    DATABASE_URL,
    connect_args={
        "check_same_thread": False,
        "timeout": 30,         # Wait 30s if DB is locked
    },
    pool_size=5,               # Keep 5 connections ready
    max_overflow=10,
)
```

---

## Async vs Sync — A Critical Understanding

FastAPI supports both async and sync route handlers:

```python
# Async route (preferred for I/O-bound work)
@router.get("/timeline")
async def get_timeline(...):
    ...

# Sync route (OK if CPU-bound or using sync libraries)
@router.get("/thumbnail/{id}")
def get_thumbnail(...):
    ...
```

**Current state of Synaps**: Most routes are sync (not async) even though they're I/O-bound (database queries, file reading). This is a significant performance issue.

When a sync route runs, FastAPI runs it in a thread pool (not the main event loop). This means:
- With 1 worker + default thread pool (40 threads), you can handle ~40 concurrent requests
- But each sync DB operation blocks one thread

**Fix**: Convert database-heavy routes to async:
```python
from sqlalchemy.ext.asyncio import AsyncSession, create_async_engine

# Change DATABASE_URL to use aiosqlite:
DATABASE_URL = "sqlite+aiosqlite:///./synaps.db"

@router.get("/timeline")
async def get_timeline(..., db: AsyncSession = Depends(get_async_db)):
    result = await db.execute(select(MediaFile).order_by(desc(MediaFile.date_taken)))
    items = result.scalars().all()
```

This is a larger refactor but would improve concurrent performance significantly.

---

## Memory Usage Analysis

| Component | Memory |
|-----------|--------|
| Python interpreter (FastAPI) | ~60–80MB |
| SQLAlchemy connection pool | ~10MB |
| `existing_paths` set (10k files) | ~5MB |
| Batch list (100 MediaFile objects) | ~2MB |
| Pillow (loading a 12MP photo) | ~50MB peak during thumbnail |
| Next.js server (production) | ~150–250MB |
| **Total minimum** | ~300MB |
| **Total peak (during scan + thumbnail gen)** | ~500MB |

On a 2GB NAS, this leaves ~1.5GB for the OS and other services. Comfortable.

On a 1GB NAS, this would be tight. Reduce `per_page` defaults (e.g., to 40) and consider disabling HEIC thumbnail generation (it can spike to 200MB+ for large HEIC files).

---

## Pagination Strategy

Current configuration: 80 items per page.

For weak hardware, consider:
- **Timeline**: 40–60 items per page (each thumbnail request is separate)
- **Finder files**: 100 per page (they're just file info, not images)
- **Search results**: 30–50 per page

```python
# config.py — add these:
TIMELINE_PER_PAGE_DEFAULT = 40
FINDER_PER_PAGE_DEFAULT = 100
SEARCH_PER_PAGE_DEFAULT = 30
```

---

## Caching Strategy

### Current Caching

| Layer | What's cached | Duration |
|-------|--------------|---------|
| Thumbnail disk cache | WebP files on disk | Forever |
| Browser cache | Thumbnail images | Browser default |
| Next.js | Static assets | Deployment lifetime |
| SQLite | In-memory pages | Connection lifetime |

### What's NOT Cached (But Should Be)

1. **Timeline groups**: Fetched fresh on every page load. A 30-second memory cache would reduce DB queries significantly.

2. **Media stats**: Queried on every timeline load. Cache for 5 minutes.

3. **Directory tree**: Fetched fresh on every Finder load. Cache for 30 seconds.

**Simple in-memory cache for FastAPI:**
```python
import time

_stats_cache = {"data": None, "expires": 0}

@router.get("/stats")
def get_stats(db: Session = Depends(get_db)):
    if _stats_cache["data"] and time.time() < _stats_cache["expires"]:
        return _stats_cache["data"]
    
    # Compute stats...
    result = {...}
    
    _stats_cache["data"] = result
    _stats_cache["expires"] = time.time() + 300  # Cache 5 minutes
    return result
```

---

## Network Performance

On a 100Mbps local network, transferring a 10MB file takes ~0.8 seconds. On 1Gbps, ~0.08 seconds.

**Thumbnails** (avg 15KB each, 80 per page): ~1.2MB total = ~0.1 seconds on 100Mbps. Fast.

**Original images** (avg 5MB each): 5MB = ~0.4 seconds on 100Mbps. Acceptable for full-screen viewing.

**Recommendation**: If your NAS is connected via 100Mbps, thumbnails will feel fast but full-size images (in MediaViewer) will have a 0.5–1 second delay before appearing. This is expected.

---

## Profile Before Optimizing

Before spending time on optimization, measure first:

```python
# Add to any slow route:
import time
start = time.perf_counter()
# ... your code ...
elapsed = time.perf_counter() - start
logger.info(f"Route took {elapsed*1000:.1f}ms")
```

For database queries specifically:
```python
# Enable SQLAlchemy SQL echo temporarily:
engine = create_engine(DATABASE_URL, echo=True)
# Look for slow queries (>100ms) in the output
```

Only optimize what the profiler shows is actually slow. Don't guess.
