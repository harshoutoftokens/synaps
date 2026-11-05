# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

- **The owner (Harsh)** builds, runs and maintains the NAS. They are a developer, comfortable with the terminal, and the only person who uses the web app. Their job on the web: check that the NAS is healthy, that every device is backing up, and how much space is left.
- **Family members** back up their phones and Macs through the native iPhone and Mac apps. They never open the web app.

## Product Purpose

Synaps is a self-hosted photo and file cloud for one family. The Mac and iPhone apps back up to a NAS in the house, show a green tick on everything that is safe, and let people browse the NAS. Success means every family photo exists on the NAS, nobody pays for a cloud subscription, and nothing leaves the home network.

The web app is being repositioned as the owner's control room. Its home becomes a stats dashboard: system health (CPU, RAM, temperature, disk, network), backup activity per device, and problems that need attention. It does not show photos or videos there; the native apps already cover browsing, and the existing timeline and folder pages remain as secondary pages.

## Positioning

A backup system for one household, running on hardware the family already owns. Each file is stored once, named by its SHA-256 hash, however many devices upload it. Native apps show at a glance what is already on the NAS. There are no accounts with a provider and no internet dependency.

## Operating Context

- **Hardware:** the NAS (`homecloud1`, `192.168.0.101:8000`) is a 15-year-old Core 2 Duo with 2 GB of RAM (no AVX) running Ubuntu Server. Anything running on it must be cheap in CPU and memory.
- **Network:** home Wi-Fi/LAN only. Nothing is exposed to the internet.
- **Serving:** the backend (FastAPI + SQLite) serves the web app as a static export on port 8000; there is no Node process on the NAS.
- **Usage:** the owner opens the dashboard to check on things. Which devices and screen sizes they use for this is not confirmed yet; the web app is already used from a browser on the LAN.
- **Data available:** library counts and disk usage (`/api/settings/storage-usage`), upload records per device and time (`logical_items.imported_at`, `sources.last_seen_at`), dedup data (`physical_objects`). System metrics (CPU, RAM, temperature, network, uptime) are not collected yet.

## Capabilities and Constraints

- **Stack:** Next.js 14 (App Router, static export), Tailwind CSS 3, framer-motion, lucide-react, next-themes, zustand. The backend is Python 3.10+ FastAPI with SQLite (WAL).
- **Metrics history (confirmed):** 1-minute samples for the last 24 hours and hourly averages for 30 days, stored in SQLite.
- **Alerts (confirmed):** problems are shown on the dashboard itself. No push notifications, email or Telegram for now.
- **Auth:** optional API token (`SYNAPS_API_TOKEN`), entered once in the web app.
- **Undecided:** whether disk SMART data and CPU temperature can be read on this hardware (`smartctl` and `/sys/class/thermal` access need checking on the NAS).

## Brand Commitments

- The name is **Synaps**; the NAS appears in the apps as **Home Cloud**.
- The Mac and iPhone apps follow Apple's native look (Liquid Glass on macOS 26). The web app's current tokens are described in `frontend/src/app/globals.css` as a "Liquid Glass design system", macOS Tahoe-inspired, with Apple Blue (`#0a84ff`) as the accent and the system font stack (no web fonts, so nothing loads from the internet).

## Evidence on Hand

- Real data on the NAS: the vault, uploads from the owner's iPhone and Mac, and the upload history in `synaps.db`.
- No stored history of CPU, RAM or network use exists yet; the dashboard must not show invented trends before samples are collected.

## Product Principles

1. **The NAS's health comes first.** The NAS holds the only copy of the family's photos. Disk space, disk health and backup recency outrank everything else on the page.
2. **Light on a weak machine.** Collecting and serving stats must not noticeably slow uploads or thumbnails on a Core 2 Duo with 2 GB of RAM.
3. **Honest numbers.** Show "no data yet" or "unknown" rather than placeholder or estimated values.
4. **Local only.** Nothing the dashboard needs may come from the internet: no web fonts, CDNs or external services.
