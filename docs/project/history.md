# Project History — Synaps

*A development journal. The goal of this document is that you can read it months later and immediately understand why every major decision was made, what problems existed before each solution, and what was learned.*

---

## Phase 1 — First Working Build
**Date:** May 21, 2026
**Commit:** `5fce9da` — *"first working build"*

### The Goal

Build a personal media browser that runs on a home NAS. The frustration driving this was simple: years of photos and videos were scattered across directories on the NAS — iPhone photos in one folder, Mac screenshots in another, family member folders in a third — and there was no good way to browse them all together without mounting the drive and scrolling through Finder.

The model in mind from day one was Apple Photos. Chronological timeline, thumbnails, a fullscreen viewer. But running locally, with no cloud subscription, no privacy concerns, and no data leaving the house.

### Architecture Decisions Made

**Why FastAPI?**
FastAPI was chosen for the backend because it auto-generates API docs at `/docs`, handles async natively (important for background scanning), and has a fast development loop. Python was the right language because the ecosystem for file processing (Pillow, exifread, ffprobe subprocess calls) is excellent.

**Why SQLite?**
The NAS has limited RAM — an old Core2Duo machine repurposed as a home server. PostgreSQL requires a running daemon that eats memory. SQLite is a single file (`synaps.db`) that lives next to the application. For a 1–2 user personal NAS with no concurrent writes, SQLite is the correct choice and not a compromise.

**Why Next.js?**
Next.js was chosen primarily for its proxy rewrite feature. Rather than configuring CORS on the FastAPI backend, all `/api/*` calls from the browser are intercepted by the Next.js server and forwarded to FastAPI on port 8000. From the browser's perspective, everything is served from a single origin. This is simpler, more secure, and removes an entire category of configuration errors.

**Why lazy thumbnail generation?**
The NAS is slow. Pre-generating thumbnails for thousands of photos at startup would take hours and block the application from being usable. Instead, thumbnails are generated the first time a browser requests them, then cached permanently on disk. The first time you open the timeline it's slow; every time after that it's instant.

**Why 80 items per page?**
A rough estimate: 80 JPEG thumbnails at ~20 KB each = ~1.6 MB per page load. The NAS has 4 GB RAM total, shared with other processes. Loading everything at once would be a memory disaster. Eighty items gives a full screen of content without excessive memory pressure.

### What Was Shipped

In a single giant commit (`90 files, 10,438 insertions`), the entire application was created:
- Full FastAPI backend with 6 routers (media, finder, sync, search, trash, settings)
- Full Next.js frontend with 6 pages (timeline, finder, sync, search, trash, settings)
- Scanner, thumbnail generator, database models
- Setup and start scripts
- Mock storage for local development

### Lessons Learned

The scanner worked but had incorrect directory walking logic. The timeline loaded, but the item counts shown per month group didn't match actual displayed items. These bugs were subtle enough to not block the first demo but needed fixing immediately.

---

## Phase 2 — Scanner Fix & NAS Hardening
**Date:** May 21–25, 2026
**Commits:** `4d718bb`, `da83df6`, `8cfe133`, `d88ff44`, PR #1 (`scanner_fix` branch)

### The Problem

After running on the real NAS for the first time, two problems surfaced immediately:

1. **The scanner was reading from the wrong root directory.** The configuration pointed to the NAS storage root, but the photos were nested inside `Vault/Harsh/Iphone/`, `Vault/Dad/Memories/`, etc. The scanner was either finding everything (including system files it shouldn't index) or nothing at all, depending on configuration.

2. **Timeline counts were wrong.** The month-group headers showed, for example, "42 photos" but the grid only displayed 35. This was a grouping bug in the API response — the total count included items on other pages.

### The Fix

The scanner's directory walking logic was rewritten. `ALLOWED_SCAN_PATHS` in `config.py` was scoped correctly to the `Vault/` subdirectory. The update script (`update.sh`) had a broken Python venv path reference that prevented NAS deployments from working.

This phase also established the deployment tooling that would be used from here on:
- `deploy.sh` — push from dev machine to GitHub
- `update.sh` — SSH into NAS, pull latest, rebuild
- `start-prod.sh` — start without hot-reload (lower memory, more stable on NAS)

### First Pull Request

The scanner fix was isolated into a `scanner_fix` branch and merged via PR #1. This was the first use of the GitHub PR workflow on this project — a deliberate decision to practice cleaner version control even for a personal project.

### Lessons Learned

The NAS environment is not like a development machine. Paths are different, case sensitivity matters (the NAS runs Linux), and the hardware is slow. Always test on the real target hardware after every significant backend change. The `update.sh` script became essential for quick iteration without manual SSH steps.

---

## Phase 3 — Import Manager
**Date:** May 28 – June 2, 2026
**Commits:** `bb8cad5`, `dc8a62e`, `0498f2c`, `d959f56`, `0d55cfa`, `14c1ecb`, `0422632`, `8e48742`, `0a4c1ae`, `2402f2e`, `d0d303a`, `b83b584`, `6201edb`, `7c6c48d`

### The Problem

The existing Sync feature (iPhone → NAS upload) was functional but had a fundamental design problem: it dumped all uploaded photos into a flat directory. After months of use, you'd have thousands of photos in a single folder with no date organization.

More importantly, photos were already sitting in an `Imports/` staging folder on the NAS — photos that had been transferred from the iPhone via other means (Lightning → Mac → NAS). These needed to be organized into the `Vault/YYYY/MM/` structure that the scanner expected. There was no tool to do this automatically.

The Import Manager was built to solve this permanently.

### Design Decisions

**Why manual trigger, not automatic?**
The Import Manager was deliberately designed with no automatic watchers or filesystem monitoring. The reason: automatic triggers are unpredictable. If a half-copied file is detected and immediately moved, it can corrupt the import. By requiring the user to explicitly press "Preview" and then "Import", the system is deterministic. You always know exactly what will happen before anything moves.

**Why a job-based polling architecture?**
The import folder during testing had ~9 GB of photos. An API endpoint that blocks for minutes would time out in Next.js (which has a 10-second API timeout in development mode). The solution was to convert the import into a background job: the API creates a job, starts a daemon thread, and returns the job ID immediately. The frontend polls `/api/import/status/{job_id}` every second until completion.

**Why show a Preview before importing?**
Importing is destructive — files are moved, not copied. Getting it wrong is recoverable (files go to the wrong folder, not deleted), but inconvenient. The Preview phase runs all the date extraction and destination routing logic without touching any files, showing the user exactly where everything will land. This caught several edge cases (photos with no EXIF date routing to `Unknown_Date/`) before they became problems.

**Content-based duplicate detection design:**
The two-stage duplicate check (file size first, then SHA-256 hash) was specifically designed for NAS performance. SHA-256 of a large video file is expensive. By checking file size first, the expensive hash computation only runs when two files have the same size — which is relatively rare. This keeps import time reasonable even for large batches.

### Problems Encountered

- **HEIC dates were wrong.** The existing `exifread` library couldn't read HEIC metadata without `pillow-heif` being registered first. Photos showed as "January 1, 1970" until this was fixed.
- **Video dates were wrong.** The `ffprobe` subprocess was being called but the output parsing had an error. Fixed by correcting the JSON path to the `creation_time` tag.
- **Uvicorn auto-reload caused chaos.** During development, Uvicorn was configured to watch for file changes and reload. Every time a thumbnail was written to disk, Uvicorn detected a "change" and restarted — killing any running import jobs. Disabled auto-reload for the thumbnail directory.
- **Preview timeouts.** The initial preview implementation was synchronous — it blocked the API endpoint. For a 9 GB import, this caused a 60-second timeout. Fixed by making preview async (same job-based polling architecture as the import itself).
- **`IMPORT_SOURCE_DIR` case sensitivity.** On the Linux NAS, `Iphone` ≠ `iphone`. The path had to match the NAS directory casing exactly. This caused a silent failure where the import folder appeared empty.

### What Changed in the Stack

The `content_hash` (SHA-256) column was added to both `MediaFile` and `SyncRecord`. A migration script (`migrate_hashes.py`) backfilled hashes for all existing records. The `scanner.py` got a new `compute_content_hash()` function.

The thumbnail queue was also significantly improved during this phase: switched from FIFO to LIFO, added multiple worker threads. This dramatically improved the timeline loading experience — thumbnails for the items currently visible load first rather than waiting for all items ahead of them in the queue.

### Lessons Learned

Background job architecture (create job → daemon thread → poll for status) is the correct pattern for any operation that takes more than a few seconds. It should be the default design for anything touching the filesystem. File operations on a slow NAS take far longer than expected — always design for "this could take minutes."

---

## Phase 4 — Media Browser & Source Filters
**Date:** June 2, 2026
**Commits:** `a3091bd`, `9bda9ac`, `4e59c8d`

### The Problem

After the Import Manager was running, the timeline became much more useful — but also much longer. Photos from the iPhone, Mac, and Windows laptop were all mixed together. If you wanted to find only iPhone photos from a specific month, you had to scroll through everything.

There was also a UX problem: all photos showed in a single continuous grid. There was no way to quickly jump to a different view density or see an "archive" of older photos separately from recent ones.

### Design Decisions

**Source filtering via the `source` column:**
The NAS directory structure already encoded device information — `Vault/Harsh/Iphone/` is obviously iPhone photos, `Vault/Harsh/Mac/` is Mac. The scanner was updated to read the parent folder name and map it to a normalized source identifier via `SOURCE_MAPPING` in `config.py`. A new `source` column was added to `MediaFile`. A database migration (`add_source_column.py`) backfilled the source for all existing records based on their path.

The timeline API was updated to accept an optional `?source=iphone` query parameter. The frontend added source filter buttons to the timeline toolbar.

**Gallery vs Timeline view:**
Gallery view is a denser grid where each cell is a fixed square thumbnail — optimized for seeing as many photos as possible at once. Timeline view groups items by month with date headers — optimized for temporal navigation. These are both valid browsing modes depending on what you're trying to do, so both were exposed as a toggle.

**Old Photos archive:**
Media taken before 2024 is automatically separated into an "Old Photos" section at the bottom of the timeline. The cutoff year is configurable via `ARCHIVE_CUTOFF_YEAR` in `config.py`. This keeps the main timeline focused on recent content without hiding older memories.

**`EXCLUDED_PATHS`:**
Not all directories in the NAS should be indexed. The `Vault/Windows_laptop-HP` folder contains a Windows laptop backup — thousands of system files, not photos. `Vault/Harsh/Mac/Private` contains files that shouldn't appear in the timeline. `EXCLUDED_PATHS` was added to `config.py` to explicitly skip these during scanning.

### Lessons Learned

Adding the `source` column to an existing database with thousands of records required a migration script. This highlighted a gap: there's no formal migration framework (like Alembic). For now, one-shot Python scripts in `backend/migrations/` serve this purpose, but as the schema evolves this will become harder to manage. Alembic is on the roadmap.

---

## Phase 5 — Apple Photos UI Redesign
**Date:** June 6–11, 2026 (ongoing on `UI-redesign-opus` branch)
**Commits:** `4e59c8d`, `885e057`

### The Problem

The application worked well, but it looked like a developer-built tool. The default Tailwind CSS utilities and a dark theme were functional, but not inspiring. Every time it was opened on an iPhone, it didn't feel like a polished app — it felt like a web app.

The goal was to make it feel as close to Apple Photos as technically possible in a browser — specifically the aesthetic introduced with visionOS and later brought to iOS 18: Liquid Glass.

### Design Decisions

**Why a dedicated glass component library?**
The original approach was to apply Tailwind glass utilities inline (e.g., `backdrop-blur-md bg-white/10 border border-white/20`). This creates inconsistency — different components end up with slightly different blur amounts, opacity levels, and border treatments. Instead, four base components were extracted: `GlassButton`, `GlassPanel`, `GlassSegmentedControl`, and `GlassToolbar`. Every glass surface in the app is built on these primitives, ensuring visual consistency.

**Why a ThemeProvider instead of just CSS variables?**
Light mode support requires more than swapping color values — some components need different blur intensities, border opacities, and shadow treatments in light vs dark mode. `ThemeProvider` provides a React context that all components can read, and it reads from `localStorage` for persistence and `prefers-color-scheme` for initial detection.

**The CSS architecture decision:**
All design tokens (colors, blur values, spacing, animation timings) were moved into CSS custom properties at the `:root` level in `globals.css`. Components reference tokens, not hardcoded values. This means changing the primary accent color, for example, requires changing one line.

**Checkpoint before continuation:**
The commit `885e057` ("checkpoint before UI redesign continuation") was deliberately saved as a checkpoint on the `UI-redesign-opus` branch. The redesign touched 20 files and 1,469 insertions — too large to do in one sitting. The checkpoint preserves a known-working state so work can resume without fear of losing progress.

### What's Still In Progress

The redesign is not complete. As of the checkpoint:
- Settings page has not been fully redesigned
- Sticky date headers in the timeline are partially implemented
- The light theme needs additional contrast tuning
- Media Viewer transitions between photos need work

---

## Phase 6 — Native Mac App & Home Cloud Vault (September 30 – October 9, 2026)

The web dashboard could show what was on the NAS, but getting files onto it was still manual. Phase 6 added a native macOS app, SynapsMac, modelled on Finder: icon and list views, Finder-style selection, Quick Look, and a green tick on every file that is already on the NAS.

Behind it, uploads moved to a new "v2" storage model. Every file is stored once, named after its SHA-256 (`Vault/YYYY/MM/<sha16>_<name>`), and each device gets a hardlink mirror of its own folder structure under `Mirrors/`. Before uploading, the app asks the NAS which hashes it already has (`/api/v2/ingest/check`), so a file that exists anywhere on the NAS is linked instead of sent again. The Mac app also gained a NAS browser ("Home Cloud"), iPhone import over USB, and thumbnails pre-generated on upload.

## Phase 7 — Native iPhone App (October 3 – 9, 2026)

SynapsiOS brought the same model to the phone: an Apple Photos–style timeline with green ticks and red crosses, automatic backup on home Wi-Fi in the background, an "Uncommitted" tab, and a NAS vault browser.

## Phase 8 — Audit, Hardening & Continuous Deployment (October 13 – 15, 2026)

A full audit found that a fresh checkout of the backend could not start (two v2 modules had never been committed), that upload paths could escape the storage folder, and that deploying meant SSH-ing in and running scripts by hand. The fixes landed as a series of stacked pull requests: the missing modules, path confinement and an optional API token, streaming uploads, SQLite WAL mode, a sturdier thumbnail pipeline, and fixes across the web app and both native apps.

Deployment became automatic. One script, `./synaps`, installs and manages everything; GitHub Actions tests every change; and a timer on the NAS pulls `main` every five minutes, deploys only commits whose CI passed, health-checks, and rolls back on failure. The first deploy on the real NAS surfaced a database created by an older schema, which led to startup adding missing columns automatically.

Two iPhone features followed: photos that reached the NAS another way (through the Mac) are now matched by name and size and ticked without uploading, and a Lock Screen Live Activity shows backup progress. The audit also found that many files migrated from the old layout carry a stored hash that doesn't match their content, which is now the top item on the [roadmap](roadmap.md).

---

## Current State (October 2026)

The NAS runs the backend as a systemd service, serves the web app itself, and updates itself from `main`. The Mac and iPhone apps are the main way files reach the NAS; the web timeline is secondary. Documentation was rewritten from the code in October 2026 ([docs/README.md](../README.md)).

---

*This document should be updated at the end of each major phase.*
*See the [changelog](../../CHANGELOG.md) for a version-by-version summary and the [roadmap](roadmap.md) for what is planned next.*
