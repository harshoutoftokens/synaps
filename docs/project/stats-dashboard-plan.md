# Stats dashboard plan

A plan for turning the web app's home page into a stats dashboard for the NAS: system health, backup activity and problems that need attention, with no photos or videos. Written October 2026, before any code. Product context is in [`PRODUCT.md`](../../PRODUCT.md); this page covers the build.

## Decisions so far

| Question | Decision |
|---|---|
| Who uses it | Only the owner. Family members use the Mac and iPhone apps and never see it. |
| Where it lives | It **replaces the web app's home page** (`/`). The photo timeline moves to `/library`; Finder, Search, Trash and Settings stay as they are. |
| Metrics history | 1-minute samples for the last 24 hours, hourly averages for 30 days, in SQLite. |
| Problems | Shown on the dashboard itself. No notifications for now. |
| Visual reference | The dark card dashboard the owner shared (October 20, 2026): a grid of rounded dark cards, big numbers with small trend labels, bar and line charts with one highlighted bar, and an activity table at the bottom. The visual direction is set in the design phase (see *Phases*), not in this plan. |

## What the dashboard shows

Ordered by importance (the NAS holds the only copy of the family's photos, so its health and backup recency come first). Each card maps to a card type from the reference.

| # | Card | Shows | Reference card it borrows from |
|---|---|---|---|
| 1 | **Needs attention** | A list of current problems, or "All good" with the time of the last check. Hidden details expand inline. | Full-width strip at the top (new) |
| 2 | **Disk** | Used / free / total for the storage volume, a ring, and an estimate of "full in ~N months" from the 30-day growth rate. SMART status when available. | "User reach" ring |
| 3 | **CPU** | Current use, load average, and a 24-hour chart. | "Order" bars |
| 4 | **Memory** | Used / available / swap, with a 24-hour line. | "Profit" line |
| 5 | **Temperature** | CPU temperature now and over 24 hours, if the sensors can be read. | Small stat card |
| 6 | **Network** | Current in / out speed, and data transferred today. | Small stat card with trend |
| 7 | **Uptime** | System uptime, backend uptime, last restart. | Small stat card |
| 8 | **Backups over time** | Files (or bytes) backed up per day for 30 days, today's bar highlighted, toggle files / size. | "Total Transaction" bar chart |
| 9 | **Devices** | Each device (Harsh's iPhone, Harsh's Mac, ...): last backup time, file count, total size, and a warning when a device hasn't backed up in 7 days. | "Total sales" list |
| 10 | **Storage breakdown** | Photos / videos / documents, space saved by deduplication, thumbnail cache, trash. | "Earning report" list |
| 11 | **Services** | Thumbnail queue length, last scan, last housekeeping run, database size, API token on/off. | Small list card |
| 12 | **Recent activity** | Latest uploads and events: time, device, file name, size, result. Paged. | Invoice table |

Everything uses real data. Before samples have been collected (first minutes after the update), charts show "Collecting data since 9:41 PM" instead of an empty or invented line.

### Problems shown under "Needs attention"

| Rule | Level |
|---|---|
| Disk over 85% full / over 95% full | Warning / critical |
| SMART reports a failing disk, or reallocated or pending sectors are rising | Critical |
| A device hasn't backed up in 7 days | Warning |
| CPU temperature over a threshold for 10+ minutes (threshold set once the real sensor values are known) | Warning |
| Memory: swap use climbing, or available memory under 100 MB for 10+ minutes | Warning |
| Thumbnail queue stuck (not shrinking for 30 minutes) | Warning |
| API token not set | Info |
| Off-site backup older than 2 days (once off-site backup exists; see [roadmap](roadmap.md)) | Warning |

## How it works

### Backend: collecting metrics

A new module `backend/system_metrics.py`, started from `lifespan` as a daemon thread next to the existing housekeeping thread.

- **Source:** read the Linux `/proc` and `/sys` files directly: `/proc/stat` (CPU), `/proc/meminfo` (memory), `/proc/loadavg`, `/proc/uptime`, `/proc/net/dev` (network), `/sys/class/thermal` or `/sys/class/hwmon` (temperature), and `os.statvfs` (disk). No new Python dependency, nothing to compile for the Core 2 Duo, and each read costs microseconds. On a Mac (local development) the readers return "unavailable", so the dashboard shows that state instead of crashing.
- **Sampling:** every 60 seconds. CPU and network values are rates, computed from the difference between two reads.
- **Storage:** two new SQLite tables:
  - `system_metrics_minute`: one row per minute, rows older than 24 hours deleted. About 1,440 rows.
  - `system_metrics_hourly`: one row per hour with average and max values, rolled up from the minute table, rows older than 30 days deleted. About 720 rows.
  - Writes are one small insert per minute, so they don't compete with uploads.
- **SMART data:** `smartctl` needs root, and the web server shouldn't get more sudo rights (today's sudoers rule only allows restarting the services). Instead, a root systemd timer (`deploy/systemd/synaps-smart.timer`, hourly) runs `smartctl --json -H -A` and writes the result to a file the backend reads. Installed by `./synaps install`.
- **Backup history:** computed from data that already exists: `logical_items.imported_at` and `physical_objects.file_size` grouped by day and source, and `sources.last_seen_at` for each device's last backup. No new table needed; add an index on `logical_items.imported_at` if the 30-day query is slow on the NAS.

### Backend: API

All under `/api/system`, protected by the existing API token.

| Endpoint | Returns |
|---|---|
| `GET /api/system/now` | Latest values for every card, plus the problem list. Cheap; polled by the page. |
| `GET /api/system/history?range=1h\|24h\|7d\|30d` | Time series for CPU, memory, temperature and network (minute rows for 1h/24h, hourly rows for 7d/30d). |
| `GET /api/system/backups?days=30` | Per-day file counts and bytes, overall and per device. |
| `GET /api/system/devices` | Each source: name, platform, last backup, file count, total size. |
| `GET /api/system/activity?page=` | Recent uploads and events, newest first. |

Storage numbers reuse `library_counts` and `_disk_usage` from `routers/settings.py`.

### Web app

- **Routing:** the dashboard becomes `src/app/page.tsx`. The current timeline moves to `src/app/library/page.tsx`, and the sidebar gets a "Dashboard" entry at the top and "Library" below it.
- **Data loading:** `/api/system/now` every 10 seconds and history every 60 seconds, only while the tab is visible (Page Visibility API), so a forgotten open tab doesn't keep the NAS busy.
- **Charts:** small hand-written SVG components (bars, line, ring, sparkline) rather than a chart library. The dashboard needs four simple chart types, and this keeps the bundle small and avoids loading anything from the internet.
- **States:** loading, "collecting data", "sensor unavailable", and NAS unreachable each get a designed state, not a blank card.
- **Layout:** a card grid that collapses to one column on narrow screens.
- **Theme:** dark and light, via the existing `next-themes` setup.

## Phases

Each phase is its own GitHub issue (labelled `enhancement`) and pull request, following the usual workflow.

1. **Metrics collector and API.** `system_metrics.py`, the two tables, the rollup, the `/api/system/*` endpoints, and pytest coverage. The SMART timer is included if `smartctl` works on the NAS. Check on the NAS: memory and CPU overhead of the collector stay negligible.
2. **Design direction.** Run `/impeccable shape` on the dashboard, then `/impeccable` new-work to settle the visual world from the reference image and the existing web app tokens, and record it in `DESIGN.md`. The open question to settle here: the reference is a dark charcoal, green-accent look, while the current web app uses a light/dark "Liquid Glass" theme with Apple Blue.
3. **Dashboard page.** Build the cards with real data, move the timeline to `/library`, update the sidebar. The impeccable hooks check each UI edit as it's written.
4. **Needs attention and polish.** The problem rules, device staleness, "disk full in N months". Then a review pass with the `web-design-guidelines` skill and `/impeccable audit` and `polish`, and a check of the static export served by the backend on the NAS.

## To check on the NAS before phase 1

- Whether `smartctl` is installed (`smartmontools`) and which device holds `/storage`.
- Which temperature sensors exist (`ls /sys/class/thermal /sys/class/hwmon`); old Core 2 Duo boards sometimes expose none without `lm-sensors`.
- The network interface name to report (`ip -br link`).
- How long the 30-day backup query takes on the real `synaps.db`.
