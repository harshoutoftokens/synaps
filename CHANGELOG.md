# Changelog

All notable changes to Synaps are documented here.
Versions are grouped by major development milestone rather than individual commits.

---

## Unreleased – Documentation & project layout

### Changed
- Documentation rewritten from the current code: 13 numbered guides in [`docs/`](docs/README.md), including new guides for storage and ingest, the Mac app and the iPhone app
- README rewritten
- One-off maintenance scripts moved from the `backend/` root (and `scripts/`) into [`backend/scripts/`](backend/scripts/README.md); run them as `venv/bin/python scripts/<name>.py` from `backend/`
- Project notes moved into `docs/project/` (`roadmap.md`, `history.md`, `versioning.md`)

### Removed
- Outdated docs superseded by the rewrite: the architecture critique (its open items moved to the roadmap), the separate diagrams file (diagrams now live in the guides), and the old future-improvements list

---

## v2.2 – Reliability, Security & Continuous Deployment *(October 13–14, 2026)*

> A full audit of the NAS backend, web dashboard and both apps. The backend could not start from a clean checkout, uploads could write outside the storage folder, and deploys were manual. This release fixes those, adds streaming uploads and a CI/CD pipeline that updates the NAS by itself, and adds two iPhone features.

### Added
- **`./synaps`** — one tool for install, dev, test, update, rollback, deploy, status, logs and doctor
- **CI** (`.github/workflows/ci.yml`): backend tests (Python 3.10 and 3.12), web lint and static build, deploy-script checks, Mac build and tests, iPhone build
- **NAS auto-update**: `synaps-update.timer` deploys new `main` commits once CI passes, backs up the database, health-checks, and rolls back on failure
- **`deploy/`** templates: systemd units, a sudoers rule limited to restarting Synaps, avahi so the NAS is reachable as `<hostname>.local` and advertised over Bonjour
- **Streaming uploads**: `PUT /api/v2/ingest/stream` (raw body, SHA-256 verified, 507 when the disk is nearly full); apps fall back to multipart on older servers
- **Optional API token** (`SYNAPS_API_TOKEN`) for the API, the web app and both apps
- **"Already on the NAS" matching**: `POST /api/v2/ingest/match` (file name + size); the iPhone app and the Mac app's iPhone view tick photos that reached the NAS another way, without uploading
- **iPhone Lock Screen progress** (Live Activity): progress bar with `x/total`, current file, "Your backup is complete" or "Backup paused" with the reason
- `/api/health` reports the NAS host name (`name`), shown on the Lock Screen instead of its IP
- Static web mode: the backend serves the exported web app, so no Node.js process runs on the NAS

### Changed
- SQLite runs in WAL mode with a 30 s busy timeout; extra indexes for timeline paging and duplicate checks
- Thumbnails: bounded worker queue, faster JPEG decoding, EXIF orientation, video frames via ffmpeg at low priority, failure memory
- Downloads and media support ETag/304 and HTTP Range; HEIC previews are cached
- Finder listings are paged and cached; the web grid only renders what is on screen
- iPhone app: background uploads continue while the app is suspended; Live Photos, videos and edits are exported as separate parts
- Mac app: new sync engine with streaming uploads, retries and a settings window for the NAS address and token

### Fixed
- The backend crashed on a fresh checkout because `models_v2.py` and `node_manager.py` had never been committed
- Upload paths are confined to the storage root (a crafted `original_path` could write outside it)
- On startup the database gains any column an older schema lacks (the timeline returned 500 on the NAS after deploying)
- Trash moves stay on the same disk, never overwrite on restore, and refuse app-uploaded (v2) files instead of breaking the vault
- The scanner refuses to delete most of the catalog when the storage disk is not mounted
- Search escapes `%` and `_`; settings only accept known keys

### Removed
- `setup.sh`, `start.sh`, `start-prod.sh`, `deploy.sh`, `update.sh`, `git_cheatsheet.md` (replaced by `./synaps`)
- Legacy `clients/mac/synaps_mac.py` CLI (superseded by the Mac app; it shared and reset the app's sync state)
- Orphaned `tests/test_sync_navigation.swift`, unused `clients/ios/SynapsiOS/Package.swift`, ad-hoc `test_db.py` / `test_heic.py` scripts

### Known issues
- Many files migrated from the old `Vault/Harsh/Iphone` layout have a stored SHA-256 that does not match their content, so hash-based dedup misses them (see [roadmap](docs/project/roadmap.md))
- Most web-timeline rows on the NAS point at files moved by an earlier restructure; the website is secondary and this is not fixed

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

## v2.0 – Native Mac App & Home Cloud Vault *(September 30 – October 9, 2026)*

> Synaps grew from a web dashboard into a multi-device cloud. A native macOS app syncs Mac folders to the NAS, files are stored once in a content-addressed vault no matter how many devices upload them, and the NAS can be browsed from the Mac like a Finder location.

### Added
- **SynapsMac** (`clients/mac/SynapsMac`) — SwiftUI app modelled on Finder: icon and list views, Finder-style selection, Quick Look, sorting, kind grouping, monochrome sidebar icons
- **Folder sync with green ticks** — local files are hashed, checked against the NAS (`/api/v2/ingest/check`) and uploaded only if the NAS doesn't have them; status persists across navigation
- **Content-addressed vault** — uploads stored once as `Vault/YYYY/MM/<sha16>_<name>`, with per-device hardlink mirrors under `Mirrors/`
- **Home Cloud browser** — browse NAS folders from the Mac with thumbnails, date sorting and a path bar
- **iPhone import over USB** into `~/Pictures/Synaps Imports`
- **Thumbnail pre-generation** — thumbnails queued automatically on upload, plus `preheat_thumbnails.py` for existing files
- Persistent folder access through security-scoped bookmarks; persistent activity log

### Fixed
- HEIC and MOV thumbnails, 4K HEVC video frame extraction, NAS connection status, sorting across all pages of a NAS folder

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

*Versions follow a milestone-based scheme. See [docs/project/versioning.md](docs/project/versioning.md) for the versioning strategy.*
