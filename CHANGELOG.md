# Changelog

All notable changes to Synaps are documented here.
Versions are grouped by major development milestone rather than individual commits.

---

## v2.1 – Native iOS Photos Companion *(October 2026)*

> Introduces the native iOS Photos client (`clients/ios/SynapsiOS`), bringing continuous timeline scrolling, automated Wi-Fi background backup, visual commit badging, and remote NAS vault exploration to iPhone devices.

### Added
- **Native iOS Photos Client** (`SynapsiOS`) — built with SwiftUI, PhotoKit, and BackgroundTasks framework
- **Continuous Timeline Scroll** — seamless, uninterrupted grid matching Apple Photos with dynamic date range subtitles (`23 – 27 Sep 2026`) and top gradient blur
- **Visual Vault Badging** — 🟢 green tick for committed photos/videos, 🔴 red cross for uncommitted media awaiting backup
- **Wi-Fi Background Sync** — automated Wi-Fi connectivity monitoring via `NWPathMonitor` with `BGTaskScheduler` background execution
- **Manual Selection & Pre-Check** — multi-select sync toolbar with zero-byte instant deduplication (`/api/v2/ingest/check`)
- **Uncommitted Staging Tab** — dedicated overview of pending files with total transfer size and one-tap "Commit All" action
- **NAS Vault Explorer** — remote directory and file browser directly on iPhone
- **Local SQLite State Store** — persistent cache for asset hashes and audit logs

---

## v0.5 – Apple Photos UI Redesign *(June 2026)*

> Major visual overhaul. The entire interface was rebuilt with a Liquid Glass aesthetic inspired by Apple Photos. This is the most significant frontend change in the project's history.

### Added
- **Liquid Glass design system** — frosted glass panels, blurred backgrounds, and translucent UI surfaces across all pages
- **Glass component library** — `GlassButton`, `GlassPanel`, `GlassSegmentedControl`, `GlassToolbar` as standalone reusable primitives
- **Light and Dark theme** — full system-level theme support with `ThemeProvider`; all components respond to theme context
- **Redesigned Sidebar** — animated, pill-style navigation with active state indicators; collapsible on mobile
- **Redesigned TopBar** — inline search with glass treatment; integrated scan trigger
- **Redesigned MediaViewer** — full-screen modal with blur backdrop, metadata panel slide-in, glass controls
- **Refined Timeline page** — sticky year/month section headers, improved grid density, smoother scroll behavior
- **Redesigned Sync page** — drag-and-drop upload area with glass card treatment and animated progress
- **ThemeProvider component** — system-preference aware, localStorage-persisted theme switching
- `EXCLUDED_PATHS` configuration for `copy_sample_media` dev helper script

### Changed
- Complete rewrite of `globals.css` — all design tokens, color variables, and animation utilities centralized
- `tailwind.config.ts` overhauled — custom color palette, glass utilities, animation keyframes added
- `store.ts` expanded — sidebar state, theme state, and active-source tracking added to Zustand store
- `AppShell.tsx` updated to wire theme context and sidebar collapse state

### Internal
- Git checkpoint saved as `UI-redesign-opus` branch before continuing refinement
- `feature/excluded-paths-and-sampler` branch tracks `EXCLUDED_PATHS` config addition

---

## v0.4 – Media Browser & Source Filters *(June 2, 2026)*

> The timeline evolved from a flat scroll into a full media browser. Gallery View, source-based filtering, and the "Old Photos" archive were all introduced in a single major architectural commit.

### Added
- **Gallery View** — dense grid mode alongside the existing timeline chronological view; user can toggle between them
- **Source Filters** — filter timeline by device source: iPhone, Mac, or Windows. Driven by the new `source` column on `MediaFile`
- **Old Photos archive** — media taken before the configurable `ARCHIVE_CUTOFF_YEAR` (default: 2024) is automatically grouped into a separate "Old Photos" section in the timeline
- **`SOURCE_MAPPING`** in `config.py` — maps NAS Vault folder names (`Iphone`, `Mac`, `Windows_laptop-HP`) to normalized internal identifiers
- `add_source_column` database migration script to backfill the `source` field on existing records
- `ARCHIVE_CUTOFF_YEAR` config setting to control the Old Photos cutoff year

### Changed
- `scanner.py` updated to extract and store the `source` field during indexing
- `routers/media.py` updated — timeline endpoint accepts optional `source` filter query parameter
- `frontend/src/lib/api.ts` — `getTimeline()` updated to pass source filter through
- Timeline page (`page.tsx`) significantly refactored — section grouping logic rewritten to support gallery/timeline modes and source filtering

### Internal
- Database cleanup tool enhanced with dry-run mode, verification reports, and extended duplicate detection (`audit_duplicates.py`)

---

## v0.3 – Import Manager *(May 28 – June 2, 2026)*

> The most complex backend feature added to Synaps. A complete manual import pipeline was built from scratch, turning the app from a passive browser into an active media organizer.

### Added
- **Import Manager** (`backend/import_manager.py`) — full background import pipeline with job tracking and poll-based progress API
- **Preview mode** — async background job that scans the import folder and shows exactly where each file will land before committing
- **Import execution** — moves files from the staging `Imports/` folder into the organized `Vault/` structure, sorted by year/month
- **Automatic date routing** — files dated before `IMPORT_OLD_PHOTOS_CUTOFF` go to `Old_Photos/`, others to `YYYY/MM/` subfolders
- **Content-based duplicate detection** — two-stage SHA-256 + file-size comparison against both `media_files` and `sync_records` tables; exact duplicates are skipped automatically
- **Unknown date handling** — files with no recoverable date (no EXIF, no video metadata, no filename date) are routed to `Unknown_Date/`
- **`ImportJob` dataclass** — in-memory job object with status, phase, progress (0–100), counters, and error log
- **`_JobStore`** — thread-safe singleton in-memory job registry
- **Import page** (`frontend/src/app/sync/page.tsx`) — UI for triggering preview, reviewing destinations breakdown, and launching import with real-time progress polling
- `content_hash` (SHA-256) and `hash_algorithm` columns added to `MediaFile` and `SyncRecord` models
- `compute_content_hash()` function added to `scanner.py`
- `migrate_hashes.py` — one-shot migration to backfill SHA-256 hashes for existing records
- Import job converted to async background job to handle massive import folders (tested with 9 GB+) without API timeout

### Fixed
- HEIC EXIF date extraction — `pillow-heif` integration corrected; dates now reliably extracted from iPhone HEIC files
- Video metadata date extraction — `ffprobe` parsing fixed for `.mov` and `.mp4`
- Timeline hierarchy refactor — month/year grouping corrected after import causes ordering edge cases
- Old Photos grouping — correctly separated from main timeline after import re-index
- Import routing — navigation between Import page and Timeline fixed after job completion
- `has_thumbnail` field missing from `MediaItem` TypeScript interface — added
- React `map()` key error on preview completion — fixed
- `IMPORT_SOURCE_DIR` case sensitivity — corrected to match exact NAS directory casing
- Import logs now visible in the "complete" job state (previously hidden on completion)
- Uvicorn auto-reload disabled — was triggering continuous server restarts whenever thumbnails were written to disk
- Thumbnail queue optimized — LIFO (last-in, first-out) queue with multiple workers so visible (recently requested) thumbnails are prioritized; dramatically speeds up initial page load
- `HEAD` method added to media routes — required to support Next.js Image Optimization preflight checks

### Internal
- `feature/import-manager` branch tracked the full import pipeline development
- `backend/.env` removed from git tracking (`.gitignore` updated)

---

## v0.2 – Scanner Improvements & NAS Hardening *(May 21 – 25, 2026)*

> After the first build, the scanner was found to have indexing issues and timeline count discrepancies. This phase focused on stability, HEIC/video metadata support, and making the app deployable on a real NAS.

### Added
- HEIC metadata extraction via `pillow-heif` — iPhone photos now have correct dates
- Video date metadata extraction via `ffprobe` — `.mov` and `.mp4` files now use embedded creation date
- `deploy.sh` — one-command Git push script for NAS deployment
- `start-prod.sh` — production startup script (no hot-reload, lower memory footprint)
- `update.sh` — NAS pull-and-rebuild script; SSH into NAS and run to update in place
- PR #1 (`scanner_fix` branch) — first ever pull request; isolated scanner fixes from main work

### Fixed
- Indexing bug — scanner was not correctly walking whitelisted directories; resulted in empty or incomplete timelines
- Timeline count discrepancy — month group item counts did not match the actual number of media items displayed
- Directory pool — scanner was reading from the wrong root path; corrected to use the proper NAS `Vault/` structure
- Update script — broken reference to Python venv path in `update.sh`

### Changed
- `scanner.py` significantly refactored — directory walking logic rewritten; whitelist enforcement tightened
- `config.py` updated — `ALLOWED_SCAN_PATHS` properly scoped to `Vault/` subdirectory

### Internal
- `scanner_fix` branch merged via PR #1 — first use of GitHub PR workflow on this project
- `directory_limit` branch tracked early experiments with scan path scoping (merged into main)

---

## v0.1 – First Working Build *(May 21, 2026)*

> The entire project was born in a single massive commit. Full-stack application — backend, frontend, database, and deployment scripts — checked in together as the first working version.

### Added
- **FastAPI backend** (`backend/`) — full REST API with startup background scan
- **Next.js 14 frontend** (`frontend/`) — TypeScript, Tailwind CSS, App Router
- **SQLite database** — single-file `synaps.db` managed via SQLAlchemy ORM
- **Media Scanner** (`scanner.py`) — async filesystem indexer; walks NAS directories, extracts EXIF dates, classifies media type, computes MD5 partial hash, writes to DB
- **Thumbnail Generator** (`thumbnails.py`) — WebP thumbnails generated on-demand and cached to disk; uses Pillow for images, ffmpeg for video frame extraction
- **Timeline page** — Apple Photos-style chronological grid grouped by month/year; infinite scroll with 80 items per page
- **Finder page** — macOS Finder-style directory browser with tree navigation sidebar
- **Search page** — filename and folder search with real-time results
- **Sync page** — file upload from iPhone/Safari with partial MD5 deduplication
- **Trash system** — soft-delete with 30-day auto-expiry; restore and permanent delete
- **Settings page** — storage usage stats, manual rescan trigger, app configuration
- **Media Viewer** — fullscreen viewer with keyboard navigation, video streaming, metadata panel, zoom
- **Database models** — `MediaFile`, `TrashItem`, `SyncRecord`, `Setting`
- **Next.js proxy rewrite** — all `/api/*` calls forwarded to FastAPI on port 8000; no CORS config needed
- **`config.py`** — centralized configuration with `SYNAPS_STORAGE_PATH`, `SYNAPS_DB_URL`, `SYNAPS_THUMBNAIL_DIR` env var overrides
- **`setup.sh`** — one-shot setup script (venv, pip install, npm install)
- **`start.sh`** — start both backend and frontend in a single terminal command
- **Mock storage** — `mock_storage/` directory with synthetic NAS file tree for local development
- **`generate_mock_data.py`** — generates mock media files across multiple family member directories
- `README.md` — initial project documentation

### Architecture Decisions Made
- SQLite chosen over PostgreSQL — no database server required; perfect for low-RAM NAS
- Thumbnails generated lazily (on demand) rather than pre-generated — avoids blocking startup on weak hardware
- Scanner runs in a background thread on startup so the API is immediately responsive
- Next.js proxy pattern chosen over CORS — simpler, more secure, single-origin from browser's perspective
- Pagination set to 80 items per page — prevents memory exhaustion on NAS with thousands of photos

---

*Versions follow a milestone-based scheme. See [VERSIONING.md](VERSIONING.md) for the full versioning strategy.*
