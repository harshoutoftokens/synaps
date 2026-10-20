# Operations

Day to day, Synaps mostly looks after itself: systemd restarts the backend if it dies, the update timer deploys merged PRs, and background threads sweep stale uploads and purge the trash. This page covers what you do when you need to look closer: health checks, logs, database backups and restores, rollbacks, the one-off maintenance scripts, the performance limits of the 2 GB Core 2 Duo, and a symptom-first troubleshooting table.

Installation and the deploy loop are in [11-deployment.md](11-deployment.md). All commands below run on the NAS from the repo root unless stated otherwise.

## Health checks

### `./synaps status`

A quick "is it up" view. On Linux it prints the systemd state of `synaps-backend.service`, `synaps-update.service` and `synaps-update.timer` (only the unit, `Active:` and `Trigger:` lines), then:

- `revision:` the commit checked out now, with its age;
- `last good deploy:` the commit in `backend/.deploy/last-good`;
- `health:` whether `http://127.0.0.1:<port>/api/health` answered within 3 s.

`/api/health` returns `{"status": "ok", "app": "Synaps", "version": "1.0.0", "name": "<hostname>"}`. It never needs the API token. The apps use the `name` field to show "homecloud1" instead of an IP address.

### Doctor

`./synaps doctor` runs a fixed list of checks and exits non-zero if any fails (the API token line only warns). It works on the Mac too; the last three checks run only on Linux.

| Check | Passes when | Fix it suggests |
|---|---|---|
| python 3.10+ | `python3` is 3.10 or newer | install python3.10 or newer |
| backend venv | `backend/venv/bin/python` exists | `./synaps install` (NAS) or `./synaps dev` (Mac) |
| backend imports | `cd backend && venv/bin/python -c 'import main'` succeeds | run that command to see the error |
| ffmpeg (video thumbnails) | `ffmpeg` is on `PATH` | `sudo apt-get install ffmpeg` |
| HEIC decode on this CPU | encoding and decoding a 16x16 HEIF image with `pillow_heif` works | pin an older `pillow-heif` in `backend/requirements.txt` |
| storage `<path>` | `SYNAPS_STORAGE_PATH` (default `mock_storage`) exists and is not empty | is the disk mounted? |
| free space N GiB | at least 2 GiB free on the storage filesystem | free up space |
| backend answering | `/api/health` responds | `./synaps status` |
| update timer active | `synaps-update.timer` is active | `sudo systemctl enable --now synaps-update.timer` |
| mDNS (avahi) running | `avahi-daemon` is active | `sudo apt-get install avahi-daemon` |
| passwordless restart | `sudo -n -l systemctl restart synaps-backend.service` is allowed | re-run `./synaps install` |
| API token | `SYNAPS_API_TOKEN` is set | warning only |

Run it after every hardware change, OS upgrade, or `pillow-heif` bump.

## Logs

`./synaps logs [N]` shows the last N lines (default 100) of all three units together:

```bash
./synaps logs            # last 100 lines
./synaps logs 500
journalctl -u synaps-backend -f          # follow the backend live
journalctl -u synaps-update --since today  # what the deploy job did
```

| Unit | What you find there |
|---|---|
| `synaps-backend` | uvicorn access log (with `token=` values redacted by `_RedactTokenFilter`), ingest warnings, thumbnail errors, "Added missing columns", housekeeping results. |
| `synaps-update` | One run every ~5 min: "up to date", "CI still running", "CI failed", or a full deploy with the commit list, pip/web build output and the health result. |
| `synaps-frontend` | Next.js server output, only in `node` web mode. |

## Backups

Before every update that changes anything under `backend/`, `backup_db` in [`synaps`](../synaps) copies the database to `backend/.deploy/backups/synaps-YYYYMMDD-HHMMSS.db`. It uses Python's `sqlite3` online backup API, so the copy is consistent even while the backend is writing. Only the newest 5 are kept. The database file is `backend/synaps.db` unless `SYNAPS_DB_URL` points elsewhere.

These backups protect the catalog only. Photos and files live on the storage disk (`/storage/Vault`, `/storage/Mirrors`) and are not backed up by Synaps.

### Restoring a database backup

Nothing restores a backup automatically, including a rollback. To restore by hand:

```bash
./synaps stop                          # stops the timer and the backend (asks for sudo)
cd backend
mkdir -p .deploy/replaced
mv synaps.db synaps.db-wal synaps.db-shm .deploy/replaced/ 2>/dev/null
cp .deploy/backups/synaps-20261014-101500.db synaps.db
cd .. && ./synaps start
```

Move the `-wal` and `-shm` files aside together with the database. The database runs in WAL mode (write-ahead log: recent writes sit in `synaps.db-wal` until they are copied into the main file), and a WAL left over from the old database must not be applied to the restored one. Anything uploaded after the backup was taken is still on disk in the Vault but missing from the restored catalog. The apps' pre-check (`/api/v2/ingest/check`) will then report those files as `need_upload`, so they may be uploaded again.

## Rollback

There are two kinds:

- **Automatic.** If a deploy fails the import check, the web build, or the 60 s health check, `cmd_update` returns to the previous commit and records the bad one in `backend/.deploy/failed`. The timer skips it until a newer commit lands. `./synaps update --force` retries it.
- **Manual.** `./synaps rollback` goes back one commit; `./synaps rollback <sha>` goes to a specific one. It rebuilds what differs, restarts and health-checks, then marks the current `origin/main` as failed so the timer doesn't jump straight back. When a newer commit is merged, the timer deploys it. To stay pinned regardless, `sudo systemctl stop synaps-update.timer`.

## Maintenance scripts

These are one-off tools in [`backend/scripts/`](../backend/scripts/), mostly from migrations of the old flat library. Run them from `backend/` with the venv's Python, so they pick up `backend/.env`:

```bash
cd ~/nas_dashboard/backend
venv/bin/python scripts/preheat_thumbnails.py --limit 500
```

Each inserts the backend directory into `sys.path`, so `config`, `database` and `models` import from any working directory. Scripts that move files print a confirmation prompt (type `yes`) in execute mode.

| Script | What it does | Flags | When to use it | Modifies |
|---|---|---|---|---|
| [`audit_duplicates.py`](../backend/scripts/audit_duplicates.py) | Groups `media_files` rows by size, hashes collisions with SHA-256, writes `duplicates_report.txt` at the repo root. | none | To see how much space exact duplicates in the v1 catalog take. | Never deletes or moves files. Does write: it fills missing `media_files.content_hash` values it computed. |
| [`clean_stale_records.py`](../backend/scripts/clean_stale_records.py) | Deletes `media_files` rows whose file no longer exists on disk, and duplicate rows. Refuses to run if the storage root is missing or empty, and keeps rows whose top-level folder is missing or empty (an unmounted disk, not deleted files). | `--dry-run` or `--execute` (one is required) | After moving or deleting files outside Synaps, when the timeline shows broken items. | Database rows only. |
| [`copy_sample_media.py`](../backend/scripts/copy_sample_media.py) | Copies a spread of up to `--limit` files per folder from a real library into a dev dataset. | `--source` (default `/storage/Vault/Harsh/Iphone`), `--dest` (default `mock_storage/Vault/Harsh/Iphone`, relative to the current directory), `--limit` (10), `--dry-run` | Building a realistic `mock_storage` for local development. | Copies files to `--dest`; never touches the source or the database. |
| [`migrate_hashes.py`](../backend/scripts/migrate_hashes.py) | Adds `content_hash` and `hash_algorithm` columns (with indexes) to `media_files` and `sync_records` if missing. | none | Historical. `init_db` now adds missing nullable columns on startup, so this is only needed for a very old database you want to migrate without starting the server. | Schema only. |
| [`move_old_media.py`](../backend/scripts/move_old_media.py) | Moves files from year folders before `--cutoff` flat into `Old_Photos/`. Never overwrites (renames with a suffix), never deletes, removes emptied folders, updates `media_files` paths and moves cached thumbnails. Refuses the Vault root and anything under `Mirrors/`. | `--dry-run` or `--execute` (required), `--cutoff` (2024), `--path`, `--no-db`, `--verbose` | Tidying an old device folder such as `Vault/Harsh/Iphone`. | Moves files and updates rows. |
| [`organize_existing_media.py`](../backend/scripts/organize_existing_media.py) | Moves files from the flat root of a folder into `YYYY/MM/` subfolders, using the scanner's own date logic. Skips duplicates, never deletes, moves cached thumbnails, refuses `Mirrors/` and v2 vault files. | `--dry-run` or `--execute` (required), `--path`, `--no-db`, `--verbose` | Organizing a flat dump of old iPhone media. | Moves files and updates rows. |
| [`preheat_thumbnails.py`](../backend/scripts/preheat_thumbnails.py) | Walks a folder newest-first and generates every missing or stale thumbnail at `nice 10`, marking `media_files.has_thumbnail`. | `--path` (relative to storage, default `Vault`), `--limit` (0 = all), `--delay` seconds, `--workers` (1) | After a big import or a restore, so browsing doesn't wait on the on-demand queue. Use `--workers 2` only when the NAS is idle. | Thumbnail cache and `has_thumbnail` flags only; never media files. |
| [`restructure_nas_mirrors.py`](../backend/scripts/restructure_nas_mirrors.py) | The one-shot migration to the v2 `Vault/YYYY/MM` + `Mirrors/` layout: consolidates `Vault_v2`, rewrites paths, rebuilds mirrors, removes empty legacy folders. Deletes a source file only when an identical copy exists at the destination. | dry run by default; `--execute`, `--yes`, `--storage-root`, `--db` | Already applied on the NAS. Kept for reference and for re-running safely. | Files, mirrors and database when executed. |

For `move_old_media.py` and `organize_existing_media.py`, always pass `--path`. Without it they default to `ALLOWED_SCAN_PATHS[0]`, which is the whole storage root, not a device folder.

## Migrations

Schema changes are mostly handled at startup by `init_db` (see [04-database.md](04-database.md)). Two scripts live in [`backend/migrations/`](../backend/migrations/):

- **[`backfill_v2_media_files.py`](../backend/migrations/backfill_v2_media_files.py)** gives every canonical Vault file (a `physical_objects` row) a v1 `media_files` row, so uploads from before ingest did this itself appear on the web timeline. It is idempotent (keyed by the unique `media_files.path`) and never indexes `Mirrors/`. For existing rows at canonical paths it fills a missing `content_hash` and replaces a meaningless `source`. Flags: `--dry-run` (report only), `--fix-reference-counts` (recompute `physical_objects.reference_count` from `logical_items`), `--fix-capture-dates` (set `media_metadata.capture_date` from EXIF/video/filename dates; files stay where they are), `--batch-size N` (commit every N new rows, default 200). Run `venv/bin/python migrations/backfill_v2_media_files.py --dry-run` first. It can run while the server is up; idle is better.
- **[`add_source_column.py`](../backend/migrations/add_source_column.py)** adds and fills `media_files.source`. Superseded: `init_db` now adds the column and fills it with the scanner's `derive_source`. It also always opens `backend/synaps.db` and ignores `SYNAPS_DB_URL`.

## Performance on a 2 GB Core 2 Duo

The NAS has two slow cores, no AVX instructions, 2 GB of RAM and a single spinning disk. Most tuning follows from that.

| Area | Setting | Why |
|---|---|---|
| Web server | One uvicorn process (`uvicorn.run("main:app", ...)` in [`main.py`](../backend/main.py), no `workers`). `synaps-backend.service` runs it at `Nice=-2`. | A second worker would double memory and fight over SQLite's single writer. |
| Thumbnail workers | `SYNAPS_THUMBNAIL_WORKERS`, default 1. Worker threads lower their own priority by 10. | Leaves the second core to request handling and SQLite. |
| Thumbnail queue | `SYNAPS_THUMBNAIL_QUEUE_MAX`, default 2000. LIFO: newest requests first; the oldest are dropped when full and re-queued when a client asks again. | What you are looking at right now gets done first. |
| Failed thumbnails | Remembered for 6 h (or until the file changes) and answered 404. | Clients polling a broken file don't re-run the decoder. |
| ffmpeg | 25 s timeout per video frame grab. | One stuck decode can't stall the queue. |
| HEIC previews | Full-size JPEG renditions for browsers, cached under `thumbnails/previews`, capped by `SYNAPS_PREVIEW_CACHE_MB` (default 1024). A request waits up to 30 s for the single converter, then gets 503 with `Retry-After: 5`. | HEIC decode is the most expensive thing the box does. |
| pillow-heif | `pillow-heif>=0.16,<2` in [`requirements.txt`](../backend/requirements.txt), floor kept low on purpose. | Newer manylinux wheels may need AVX, which the Core 2 Duo lacks. Upgrading to 1.8+ makes HEIC thumbnails about 30x faster (embedded-thumbnail path); confirm with `./synaps doctor` on the NAS before keeping it. |
| SQLite | WAL journal, `busy_timeout` 30 s (`SYNAPS_SQLITE_BUSY_TIMEOUT_MS`), `synchronous=NORMAL`, 8 MB page cache per connection. Set per connection in `_configure_sqlite` ([`database.py`](../backend/database.py)). | Readers (timeline, thumbnails) don't block on an upload's write, and a second writer waits instead of failing with "database is locked". |
| Uploads | Streamed straight to `.synaps_tmp/` on the storage disk and hashed on the fly; refused with 507 if they would leave less than `SYNAPS_MIN_FREE_BYTES` (512 MiB) free. Apps use at most 2 upload connections. | One disk write per byte, final placement is a rename. |
| Web build | `NODE_OPTIONS=--max-old-space-size=1024`, `nice 10`, only when `frontend/` changed. | Keeps the backend out of swap during deploys. |

Thumbnail internals are in [06-thumbnails-and-media.md](06-thumbnails-and-media.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Backend won't start; `./synaps status` shows it restarting every 5 s | Import error after a manual edit, a missing package, or a bad value in `backend/.env` (e.g. a non-numeric `SYNAPS_PORT`). | `./synaps logs 200` for the traceback; `cd backend && venv/bin/python -c 'import main'` reproduces it. `./synaps doctor` checks the venv and imports. |
| Backend unit stays inactive after boot, no log output | `RequiresMountsFor` on the storage path: the disk did not mount. | Mount the disk (check `/etc/fstab`), then `./synaps start`. |
| 401 on everything after setting a token | The apps or browser don't have the token, or have an old one. The server compares exactly. | Enter the same value in Mac and iPhone Settings ("Test Connection" distinguishes unreachable from unauthorized). In the browser, the dashboard prompts on 401; clear the `synaps_token` cookie if it holds a stale value. Make sure you ran `./synaps restart` after editing `.env`. |
| Thumbnails stay at 202 (spinners that never resolve) | The single worker is behind a long queue (a large folder of HEIC or 4K video), or the request was dropped from a full queue. The iPhone app stops polling after 5 tries of 202, the Mac app after 12. | Wait, or scroll back to re-request. For whole libraries, run `venv/bin/python scripts/preheat_thumbnails.py`. If HEIC never finishes, run `./synaps doctor` and look at the HEIC check. |
| HEIC thumbnails fail or the backend restarts while browsing photos | A `pillow-heif` wheel that uses instructions the CPU lacks. | `./synaps doctor`. If "HEIC decode on this CPU" fails, pin an older `pillow-heif` in `requirements.txt` via a PR. |
| Video thumbnails 404 | `ffmpeg` missing, or it timed out (25 s) and the file is now marked failed for 6 h. | `./synaps doctor`; `sudo apt-get install ffmpeg`. Failures clear when the file changes or after 6 h (or a backend restart). |
| Uploads fail with 507 | Free space on the storage disk would drop below `SYNAPS_MIN_FREE_BYTES`, or the disk is actually full (ENOSPC). Both apps stop the whole run on the first 507. | Free space on `/storage` (empty the Synaps trash, delete old files), then sync again. `./synaps doctor` shows free GiB. |
| Timeline returns 500 and the log says `no such column` | The database predates a newer model column and the running backend started before `init_db` gained `add_missing_columns`, or the new column is NOT NULL. | `./synaps restart` and look for "Added missing columns" in the log. A non-nullable column needs a manual `ALTER TABLE`. |
| Mac app looks flat, without Liquid Glass | The binary was built with Xcode 27's `swiftbuild` build system, which stamps it with SDK 14.0 (the package's minimum macOS). macOS then treats it as an old app and uses the legacy look. | Check with `otool -l SynapsMac.app/Contents/MacOS/SynapsMac \| grep -A4 LC_BUILD_VERSION`; `sdk` should be the current SDK, not 14.0. Rebuild with the default toolchain and build system: `./synaps mac` (plain `swift build -c release`). |
| Apps can't find the NAS | Wrong address in Settings (the apps default to `http://192.168.0.105:8000`; the NAS is at 192.168.0.101), the NAS got a new DHCP address, or `homecloud1.local` doesn't resolve because avahi isn't running. | Use `http://homecloud1.local:8000` or the current IP. On the NAS: `systemctl status avahi-daemon`, `hostname`, `./synaps doctor`. The Mac app suggests another answering address from a fixed list (`.105`, `.101`, `homecloud1.local`); a DHCP reservation on the router avoids the problem. |
| Web dashboard 404 at `/` but the API works | Static mode with no `frontend/live/index.html` or `SYNAPS_FRONTEND_DIST` unset (the log warns "web app not served"). | Re-run `./synaps install` (it rebuilds the web app and sets `SYNAPS_FRONTEND_DIST`). An update also rebuilds a missing `live/`, but only when there is a new commit to deploy. Needs Node 18+. |
| `synaps-update` log says "CI still running" for a long time | `ci_state` returns pending when there are no check runs yet or any run is not `completed`. A queued macOS runner, a disabled workflow, or a commit CI never ran on keeps it there. | Look at the commit's checks on GitHub. Re-run or fix CI, or deploy deliberately with `./synaps deploy --force` from the Mac. |
| `synaps-update` log says "could not read CI status from GitHub" | No network, GitHub API error, or the repository is private (the script calls the API without a token). | Check connectivity; for a private repo either make the gate use a token (code change) or set `SYNAPS_REQUIRE_CI=0` in `.synaps.local`. |
| `synaps-update` log says "local changes to tracked files" | Someone edited files in the NAS checkout. | `git status` on the NAS; move the change into a PR and `git stash` or `git checkout -- <file>` it. |
| "failed to deploy earlier - waiting for a newer commit" | That commit failed and was rolled back. | Read the failing run in `journalctl -u synaps-update`, fix it in a new PR. `./synaps update --force` retries the same commit. |
