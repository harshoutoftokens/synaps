# Synaps Roadmap

This document tracks what has been built, what is actively being refined, what is planned for near-term releases, and long-term ambitions for the project.

---

## ✅ Completed

These systems are fully implemented and functional.

### Core Infrastructure
- [x] **FastAPI backend** — REST API with async startup, router structure, auto-docs at `/docs`
- [x] **Next.js 14 frontend** — TypeScript, App Router, Tailwind CSS
- [x] **SQLite database** — Single-file via SQLAlchemy ORM; zero-config for NAS
- [x] **Next.js proxy rewrite** — All `/api/*` requests forwarded to FastAPI; no CORS config needed
- [x] **Configuration system** — `config.py` with full env var overrides (`SYNAPS_STORAGE_PATH`, etc.)
- [x] **Setup & start scripts** — one `./synaps` tool (install, dev, update, deploy) replacing the five shell scripts
- [x] **Continuous deployment** — GitHub Actions CI + NAS auto-update timer with health-checked rollback
- [x] **Mock storage** — Synthetic NAS directory tree for local development

### Media Scanner
- [x] **Async filesystem indexer** — Walks whitelisted NAS directories on startup in a background thread
- [x] **EXIF date extraction** — Reads `DateTimeOriginal` from JPEG and PNG files via `exifread`
- [x] **HEIC metadata extraction** — iPhone HEIC photos correctly dated via `pillow-heif`
- [x] **Video date extraction** — `.mov` and `.mp4` creation dates via `ffprobe`
- [x] **Filename date parsing** — Fallback date extraction from common filename patterns
- [x] **Media type classification** — Image, video; screenshot and screen recording detection
- [x] **Source detection** — Maps NAS folder structure to device source (iPhone, Mac, Windows)
- [x] **Configurable excluded paths** — `EXCLUDED_PATHS` list skips private/irrelevant directories
- [x] **Partial MD5 hashing** — Fast deduplication check (first 64 KB of file)
- [x] **Content SHA-256 hashing** — Exact duplicate detection for import pipeline

### Thumbnail Pipeline
- [x] **On-demand WebP thumbnails** — Generated on first request, cached forever to disk
- [x] **LIFO priority queue** — Most recently requested thumbnails are generated first (visible items prioritized)
- [x] **Multiple thumbnail workers** — Parallel generation to keep UI responsive
- [x] **Image thumbnails** — Pillow-based; handles JPEG, PNG, HEIC
- [x] **Video thumbnails** — ffmpeg frame extraction at 1-second mark

### Timeline & Gallery
- [x] **Timeline View** — Chronological media grid grouped by month and year
- [x] **Gallery View** — Dense grid mode, user-toggleable
- [x] **Source filters** — Filter timeline by device: iPhone, Mac, Windows, or All
- [x] **Old Photos archive** — Media before `ARCHIVE_CUTOFF_YEAR` separated into its own section
- [x] **Infinite scroll** — 80 items per page, loaded as user scrolls
- [x] **Media Viewer** — Fullscreen viewer with keyboard navigation, zoom, video streaming, metadata panel

### Import Manager
- [x] **Import staging → Vault pipeline** — Moves media from `Imports/` folder into organized `Vault/YYYY/MM/` structure
- [x] **Preview mode** — Shows exactly where each file will land before any files are moved
- [x] **Background job execution** — Import runs in a daemon thread; frontend polls for progress
- [x] **Import progress tracking** — Phase descriptions, 0–100% progress, counters (imported, skipped, errors)
- [x] **Automatic date routing** — Files routed to `YYYY/MM/`, `Old_Photos/`, or `Unknown_Date/`
- [x] **Content-based duplicate detection** — Two-stage SHA-256 + size check against both `media_files` and `sync_records`
- [x] **Post-import re-indexing** — Scanner runs automatically after import to add new files to the timeline

### Other Features
- [x] **Finder (directory browser)** — macOS Finder-style tree navigation of the NAS
- [x] **Search** — Filename and folder search with real-time results
- [x] **Sync (iPhone upload)** — Direct photo/video upload from iPhone Safari with deduplication
- [x] **Trash system** — Soft-delete with 30-day auto-expiry, restore, and permanent delete
- [x] **Settings page** — Storage usage stats, manual rescan trigger
- [x] **Database cleanup tools** — `clean_stale_records.py` with dry-run mode; `audit_duplicates.py`

### Apple Photos UI (v0.5)
- [x] **Liquid Glass design system** — Frosted glass panels, blurred backgrounds throughout
- [x] **Glass component library** — `GlassButton`, `GlassPanel`, `GlassSegmentedControl`, `GlassToolbar`
- [x] **Light and Dark theme** — System-aware; `ThemeProvider` with localStorage persistence
- [x] **Redesigned Sidebar** — Animated pill-style navigation, collapsible
- [x] **Redesigned TopBar** — Integrated search with glass treatment
- [x] **Redesigned Sync page** — Drag-and-drop upload with animated progress

---

## 🔄 In Progress

Active work on the `UI-redesign-opus` branch.

- [ ] **Sticky date section headers** — Year/month headers that pin to the top of the viewport as you scroll through the timeline
- [ ] **Timeline polish** — Consistent grid gap, hover effects, and selection state refinement
- [ ] **Sidebar improvements** — Item counts per section (e.g., "iPhone (342)"), better active state animation
- [ ] **Light theme polish** — Glass components need additional contrast tuning in light mode
- [ ] **Media Viewer refinements** — Transition animations between photos, swipe gesture support
- [ ] **Settings page redesign** — Apply full glass treatment to the settings page (currently partially updated)

---

## 📋 Planned

Near-term features targeted for v0.6 – v1.0.

### v0.6 — Stability & Polish
- [ ] **Orphan record cleanup endpoint** — API to detect and remove `media_files` rows whose file no longer exists on disk
- [ ] **Scan progress reporting** — `/api/scan/progress` endpoint + progress indicator in Settings UI
- [ ] **Hash algorithm consistency** — Unify partial MD5 (scanner) and full hash (sync) to prevent false deduplication misses
- [ ] **Restore from trash re-indexes** — Restoring a file recreates its `MediaFile` row immediately (no rescan needed)
- [ ] **Upload triggers immediate indexing** — Synced file appears in timeline instantly after upload

### v0.7 — Richer Media Info
- [ ] **Video scrubbing (Range Requests)** — Proper HTTP Range request support for seeking in videos without full download
- [ ] **Width, height, duration extraction** — Scanner populates these currently-empty model fields; video duration shown in thumbnail overlay
- [ ] **Full EXIF metadata** — Camera make/model, GPS coordinates, aperture, ISO extracted and stored

### v0.8 — Search & Discovery
- [ ] **Date-range filtering** — Filter timeline to a specific date range via a date picker
- [ ] **Full-text search improvements** — Search by date, media type, source device, and file size
- [ ] **Screenshot filter** — Toggle to show/hide screenshots from timeline

### v0.9 — Albums & Collections
- [ ] **Manual Albums** — Create named albums; add any media item to one or more albums
- [ ] **Smart Collections** — Auto-populated based on rules (e.g., "All iPhone videos from 2024")
- [ ] **Album cover selection** — Choose which photo represents an album

### v1.0 — Stable NAS Release
- [ ] **Scheduled background scans** — Scanner runs on a configurable interval (e.g., every 6 hours) without manual trigger
- [ ] **Configurable scan paths from UI** — Add/remove scan directories without editing `config.py`
- [ ] **WebSocket real-time updates** — UI refreshes automatically when scan completes or new photos are uploaded
- [ ] **Nginx integration guide** — Serve thumbnails as static files for better performance under load
- [ ] **PWA support** — `manifest.json` + service worker so Synaps can be "added to home screen" on iPhone
- [ ] **Mobile layout optimization** — Touch-friendly controls, swipe gestures, bottom navigation bar on small screens

---

## 💡 Future Ideas

Long-term ambitions. These require significant effort or powerful hardware.

### AI & Intelligence
- [ ] **AI Semantic Search** — "Find photos of sunsets" using local CLIP embeddings + `sqlite-vss`
- [ ] **Face Recognition** — Detect and cluster faces; "People" view grouping photos by person (requires `face_recognition` / dlib)
- [ ] **Object Detection** — Tag photos by detected objects (car, dog, food) using a local vision model
- [ ] **OCR on documents** — Make scanned documents and screenshots searchable by their text content
- [ ] **Automatic Tagging** — Suggest tags based on image content analysis
- [ ] **Visual Duplicate Detection** — Find visually similar photos (not just identical bytes) using perceptual hashing

### Memories & Stories
- [ ] **Memories** — Auto-generated highlight albums ("This day 3 years ago", "Summer 2023")
- [ ] **Map View** — Plot geotagged photos on an interactive map (requires GPS EXIF extraction)
- [ ] **Slideshow mode** — Full-screen auto-advancing slideshow with Ken Burns effect

### Multi-User & Sync
- [ ] **Multi-user accounts** — Separate libraries and permissions per user; family sharing
- [ ] **Remote sync client** — Background sync app on iPhone/Android that pushes new photos to Synaps automatically
- [ ] **Cloud backup integration** — Mirror the Synaps library to S3, Backblaze B2, or similar

### Performance & Architecture
- [ ] **Async database layer** — Replace SQLAlchemy sync with `aiosqlite` for better concurrency
- [ ] **Background thumbnail pre-generation** — Generate all thumbnails proactively in a background queue after scan
- [ ] **Incremental scanning** — Only re-scan directories that have changed (filesystem watch or mtime comparison)

---

*See [CHANGELOG.md](CHANGELOG.md) for what has already been shipped.*
*See [VERSIONING.md](VERSIONING.md) for the version numbering strategy.*
