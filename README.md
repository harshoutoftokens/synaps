<div align="center">

# Synaps

**Self-hosted personal media cloud & native macOS desktop client for Network Attached Storage.**

Browse, organize, stream, and synchronize your photos, videos, and files with zero cloud subscriptions and complete privacy.

[![Version](https://img.shields.io/badge/version-v2.0-blue?style=flat-square)](VERSIONING.md)
[![FastAPI](https://img.shields.io/badge/backend-FastAPI-009688?style=flat-square&logo=fastapi&logoColor=white)](backend/)
[![Next.js](https://img.shields.io/badge/frontend-Next.js_14-black?style=flat-square&logo=next.js&logoColor=white)](frontend/)
[![macOS](https://img.shields.io/badge/macOS-SwiftUI_Native-FF3B30?style=flat-square&logo=apple&logoColor=white)](clients/mac/SynapsMac/)
[![iOS](https://img.shields.io/badge/iOS-SwiftUI_Native-FF2D55?style=flat-square&logo=apple&logoColor=white)](clients/ios/SynapsiOS/)
[![SQLite](https://img.shields.io/badge/database-SQLite-003B57?style=flat-square&logo=sqlite&logoColor=white)](backend/database.py)
[![License](https://img.shields.io/badge/license-MIT_/_Personal-success?style=flat-square)](LICENSE)

[Architecture](#-architecture) • [Features](#-key-features) • [Clients](#-ecosystem--clients) • [Quick Start](#-quick-start) • [Deployment](#-nas-deployment-cicd) • [Documentation](#-documentation)

---

</div>

## Overview

**Synaps** transforms any home server or headless NAS into a high-performance personal cloud. It pairs an asynchronous FastAPI backend and a Next.js Liquid Glass web dashboard with a native macOS Swift desktop companion.

Whether backing up direct USB imports from an iPhone via ImageCaptureCore, cataloging multi-terabyte media vaults with background EXIF parsing, or synchronizing local directories with a Git-like state machine, Synaps keeps your data on your own hardware without third-party fees.

---

## ⚡ Key Features

### 📸 Apple Photos-Inspired Media Cloud
- **Chronological Timeline**: Smooth virtualized infinite scrolling grouped intelligently by month and year.
- **Old Photos Vault**: Automatically segregates media prior to a configurable cutoff date (`ARCHIVE_CUTOFF_YEAR`).
- **Dense Gallery & Finder**: Switch between Apple Photos timeline view, dense gallery grid, and hierarchical NAS directory tree.
- **Fullscreen Media Player**: In-browser hardware-accelerated video streaming with dynamic frame-accurate scrubbing, keyboard shortcuts, and detailed EXIF/codec inspection.

### ⚡ Blazing High-Performance Thumbnail Engine
- **Asynchronous Preheating**: Proactively crawls newest storage directories to pre-generate compact WebP thumbnails ahead of time.
- **LIFO Priority Scheduling**: Generates on-screen viewport thumbnails first with thread pool workers.
- **Sub-Millisecond Caching**: Multi-tier caching layer (in-memory LRU + persistent `.webp` files) for instant render times.
- **HEVC / 4K 60fps Optimization**: Fast 0.1-second keyframe seeks and resilient timeout handling for high-bitrate video clips.

### 🔄 Multi-Device Synchronization & Git-for-Files
- **Two-Stage Content Deduplication**: Fast file-size hashing followed by SHA-256 chunk checks prevents duplicate media ingestion.
- **Git-Style Status Badges**: Clear visual states for files across your devices:
  - 🔴 **Uncommitted**: Local new or modified file pending sync to NAS.
  - 🟢 **Committed**: Verified byte-for-byte identical to the NAS Vault.
  - 🟡 **Syncing**: Transfer or background hash pre-check actively in flight.
- **Directory Ingestion & Staging**: Automatic sorting into clean `YYYY/MM/` vault directories, handling 10+ GB batches effortlessly.

### 🖥️ Native macOS Companion (`SynapsMac`)
- **Built with Swift & SwiftUI**: Native macOS menu bar, sidebar navigation, keyboard shortcuts, and QuickLook previews (`Spacebar`).
- **Hardware iPhone ImageCapture Integration**: Plug in your iPhone via USB, unlock, and immediately preview and import camera roll media directly into the NAS storage pipeline.
- **Resilient Background Sync**: Non-blocking upload queues, retry loops, and native OS notifications on commit completion.

### 📱 Native iOS Photos Companion (`SynapsiOS`)
- **Authentic Apple Photos Experience**: Continuous timeline scroll with dynamic date range header, top gradient blur, and 5-column/3-column density.
- **Visual Vault Badging**: 🟢 Green checkmark for committed NAS media, 🔴 Red cross for uncommitted camera roll items.
- **Automated Wi-Fi Background Sync**: Automatically detects home Wi-Fi and triggers background upload tasks (`BGTaskScheduler`) without using cellular data.
- **Manual Selection & Pre-Check**: Multi-select sync with zero-byte instant deduplication against NAS storage.
- **Remote NAS Vault Browser**: Direct file and directory explorer on your iPhone.

---

## 🏛 Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                          Clients & Frontends                           │
├──────────────────────┬──────────────────────────┬──────────────────────┤
│  Next.js 14 Web App  │   SynapsMac (SwiftUI)    │ SynapsiOS (SwiftUI)  │
│  • Liquid Glass UI   │   • USB ImageCaptureCore │ • Apple Photos Grid  │
│  • Timeline & Finder │   • QuickLook Preview    │ • Wi-Fi Auto-Sync    │
│  • Media Streaming   │   • Git-for-Files Sync   │ • NAS Vault Browser  │
└──────────┬───────────┴────────────┬─────────────┴──────────┬───────────┘
           │                        │                        │
      HTTP / REST              HTTP / REST              HTTP / REST
           │                        │                        │
┌──────────▼────────────────────────▼────────────────────────▼───────────┐
│                   Synaps Asynchronous Backend Engine                   │
│                                (FastAPI)                               │
├────────────────────────────────────────────────────────────────────────┤
│  • Startup Filesystem Scanner & Watcher                                │
│  • LIFO WebP Thumbnail Generation Engine                               │
│  • Background Thumbnail Preheating Pipeline                            │
│  • Import Stager, Metadata Extractor & Dedup Check                     │
│  • Soft-Delete Trash Manager with 30-Day Auto Purge                    │
└───────────────────────────────────┬────────────────────────────────────┘
                                    │
        ┌───────────────────────────┴───────────────────────────┐
        ▼                                                       ▼
┌──────────────┐                                       ┌───────────────────┐
│ SQLite Store │                                       │   NAS Filesystem  │
│ (synaps.db)  │                                       │  (/storage/Vault) │
└──────────────┘                                       └───────────────────┘
```

---

## 💻 Ecosystem & Clients

| Component | Stack | Description | Location |
| :--- | :--- | :--- | :--- |
| **Backend API** | Python 3.11+, FastAPI, SQLAlchemy | High-concurrency async file ingestion, indexing, and thumbnail engine. | [`backend/`](backend/) |
| **Web Dashboard** | Next.js 14 (App Router), TypeScript, Tailwind CSS | Frosted glass interface with light/dark modes, timeline, search, and settings. | [`frontend/`](frontend/) |
| **macOS Client** | Swift 5.9+, SwiftUI, ImageCaptureCore | Native Finder-like client with direct iPhone USB import and synchronization. | [`clients/mac/SynapsMac/`](clients/mac/SynapsMac/) |
| **iOS Client** | Swift 5.9+, SwiftUI, PhotoKit | Native Apple Photos companion with Wi-Fi auto-sync and vault status badging. | [`clients/ios/SynapsiOS/`](clients/ios/SynapsiOS/) |
| **Storage Engine** | SQLite, Pillow, FFmpeg | Robust database modeling and media processing pipelines. | [`backend/models.py`](backend/models.py) |

---

## 🚀 Quick Start

### Prerequisites
- **Python**: 3.11 or higher
- **Node.js**: 18.x or higher (`npm` included)
- **FFmpeg & ffprobe**: Required for video thumbnail extraction and metadata analysis
  - macOS: `brew install ffmpeg`
  - Linux (Debian/Ubuntu): `sudo apt install ffmpeg`

### 1. Development (your Mac)

```bash
git clone https://github.com/harshoutoftokens/synaps.git
cd synaps
./synaps dev      # backend on :8000 + web app on :3000, Ctrl+C stops both
./synaps test     # backend tests, web lint/build, Mac client tests
```

Backend settings (storage path, API token, owner name, …) live in `backend/.env`; copy
[`backend/.env.example`](backend/.env.example) and uncomment what you need. Without it the backend
serves the bundled `mock_storage/`.

### 2. Native clients

```bash
./synaps mac      # build SynapsMac.app and open it
./synaps ios      # open the iPhone app in Xcode (pick your iPhone, set your Team, Run)
```

---

## 🛠 NAS Deployment (CI/CD)

One-time setup on the NAS (Ubuntu Server, over SSH):

```bash
git clone https://github.com/harshoutoftokens/synaps.git ~/nas_dashboard
cd ~/nas_dashboard
./synaps install --storage /storage
```

`install` sets up packages (ffmpeg, avahi, Python venv), builds the web app, and installs systemd units:
`synaps-backend` (API + web app on port 8000, waits for the storage disk) and `synaps-update.timer`.
It also advertises the NAS over Bonjour (`<hostname>.local`, `_synaps._tcp`) so the Mac and iPhone apps find it.

After that, deploying is just merging to `main`:

1. Every push and PR runs [CI](.github/workflows/ci.yml): backend tests, web build, Mac tests, iOS build.
2. Every 5 minutes the NAS checks `origin/main`. When a new commit has passed CI it pulls it,
   rebuilds only what changed, backs up the database, restarts, and health-checks.
3. If anything fails, it rolls back to the previous version and skips that commit until a newer one lands.

```bash
./synaps deploy           # from your Mac: tell the NAS to update now (set SYNAPS_NAS=user@host)
./synaps status | logs | doctor | rollback [rev]     # on the NAS
```

See [docs/11 — Deployment & Services](docs/11_deployment_and_services.md) for details.

---

## 📚 Documentation

Deep-dive architectural guides and developer manuals are available in the [`docs/`](docs/) directory:

- [**01 — Project Overview**](docs/01_project_overview.md): System architecture and data flow principles.
- [**02 — Backend Architecture**](docs/02_backend_architecture.md): FastAPI structure and router design.
- [**03 — Frontend Architecture**](docs/03_frontend_architecture.md): Next.js components and Liquid Glass tokens.
- [**04 — Database & Indexing**](docs/04_database_and_indexing.md): SQLite schema and models.
- [**05 — Media Scanner**](docs/05_media_scanner.md): Filesystem scanner and EXIF parser.
- [**06 — Thumbnail Pipeline**](docs/06_thumbnail_pipeline.md): Preheating engine and LIFO worker queue.
- [**07 — API Reference**](docs/07_api_reference.md): Complete REST endpoint specifications.
- [**10 — Sync Engine**](docs/10_sync_engine.md): Two-stage SHA deduplication and client state machine.
- [**11 — Deployment & Services**](docs/11_deployment_and_services.md): Production systemd, reverse proxies, and updates.

---

## 🗺 Roadmap & Milestones

- [x] **v0.1 – First Working Build**: Fast directory walking and web preview.
- [x] **v0.2 – Scanner & NAS Hardening**: Error boundaries and format resilience.
- [x] **v0.3 – Import Manager**: Staging pipeline and duplicate detection.
- [x] **v0.4 – Media Browser**: Source filters and Old Photos grouping.
- [x] **v1.0 – Stable NAS Release**: Media timeline, video streaming, and trash bin.
- [x] **v2.0 – Liquid Glass & Native Clients**: Complete Apple Photos UI rewrite, native Swift macOS client, and background thumbnail preheating.
- [ ] **v2.1 – Albums & Memory Collections**: Tagging, smart albums, and timeline story highlights.
- [ ] **v2.2 – Local AI**: On-device face clustering, semantic CLIP search, and object detection.

See [CHANGELOG.md](CHANGELOG.md) for full release notes and [ROADMAP.md](ROADMAP.md) for future specifications.

---

## 📄 License

This project is licensed under personal and open-source terms. See [LICENSE](LICENSE) for details.
