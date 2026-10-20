# Roadmap

Where Synaps stands and what comes next. Finished work is recorded in the [changelog](../../CHANGELOG.md); this page lists open problems first, then planned work, then ideas. Last reviewed October 2026.

## Known issues

These are real problems in the current system, roughly in order of impact.

| Issue | Effect | Notes |
|---|---|---|
| **Stored hashes don't match file content for many migrated files** | Hash-based dedup misses them, so the same photo can be stored twice (for example `IMG_0055.PNG` exists twice, byte-identical). | Found in October 2026: in a random sample, 14 of 25 iPhone files migrated from the old `Vault/Harsh/Iphone` layout and 2 of 25 Mac uploads had a `physical_objects.sha256` that differs from the file on disk. Fixing needs a re-hash plus a duplicate merge (files are named after their hash). See [storage and ingest](../03-storage-and-ingest.md). |
| **Web timeline rows point at moved files** | On the NAS, about 18,300 of 19,500 timeline rows still point into `Vault/Harsh/...` folders that an earlier restructure removed; opening them fails. | The Mac and iPhone apps don't use these rows. The fix is to run `migrations/backfill_v2_media_files.py` (adds ~60,000 rows for the real files) together with removing the stale rows. Deliberately not done: the website is secondary. |
| **App uploads can't be deleted through the API** | Trash returns `409` for files the apps uploaded (v2-managed), to avoid breaking the vault. | Needs a v2-aware delete: drop the logical item, decrement `reference_count`, remove the object and mirrors when nothing references it. |
| **No uniqueness on `(source_id, original_path)`** | Concurrent or retried uploads of the same path could create two logical items. | The ingest lock makes this unlikely in practice; a unique index (after cleaning existing duplicates) would make it impossible. |
| **Old secrets in public git history** | Early commits contain `backend/.env`, the NAS user name and LAN IPs. | The repository is public. Removing them requires a history rewrite (`git filter-repo`) and a force-push; rotate anything that was in `.env`. |
| **API token not set on the NAS** | Anyone on the home Wi-Fi can use the API. | Set `SYNAPS_API_TOKEN` in `backend/.env`, `./synaps restart`, enter it in the web app and both apps. |

### Smaller issues

Found while rewriting the docs from the code (October 2026). None of them lose data.

- **Vault never shrinks:** `physical_objects.reference_count` is maintained but nothing acts on it, so an object no longer referenced by any logical item stays on disk.
- **Web timeline misses some app uploads:** only `.jpg .jpeg .png .heic .mp4 .mov` uploads get a timeline row; HEIF, WebP, M4V and other files are stored but don't appear on the website.
- **Favorites live in two places:** `/api/media/favorite` updates only the timeline row, not the v2 `media_metadata`.
- **Mirror folder depends on the device's name:** an iOS source goes to `Mirrors/<Owner>/Iphone/` only if its friendly name contains "iphone" or "ios"; a renamed phone gets a top-level `Mirrors/<name>/` folder.
- **Mac app hard-codes its identity:** the mirror path (`Mirrors/Harsh/Mac/...`) and the source ids (`mac_harsh`, `iphone_harsh`) are fixed in code; the matching config fields are unused.
- **Mac app's iPhone view:** items imported over USB show as committed before the imported copy has reached the NAS, and the sidebar's "Pictures" row opens the iPhone view rather than `~/Pictures/Synaps Imports`.
- **Timeline paging uses OFFSET:** `ix_media_files_date_taken_id` was added for keyset paging, but `GET /api/media` still pages with COUNT + OFFSET, which gets slower deep into a large library.
- **`/api/sync/check-duplicate` compares different hash kinds** (whole-file MD5 vs first-64 KB MD5) and can miss duplicates.
- **`migrations/add_source_column.py` is obsolete and unsafe on today's layout:** it ignores `SYNAPS_DB_URL` and would give canonical vault files a month number as their source. Startup now adds the column itself.
- **iPhone app:** `Resources/SynapsiOS.entitlements` isn't referenced by the build settings, and the `notificationsEnabled` setting isn't read anywhere.
- **Apps default to the old NAS address** (`http://192.168.0.105:8000`; the NAS is at `.101`). The Mac app also tries `.101` and `homecloud1.local`; neither app browses the `_synaps._tcp` Bonjour service the NAS advertises.
- **Matched photos leave no NAS record:** `/api/v2/ingest/match` is read-only, so photos ticked on the iPhone through matching have no iPhone provenance (logical item or mirror) on the NAS.
- **Deploy gate waits for every CI job,** including the macOS-runner app builds, even for backend-only changes; and it reads check results without a token, so it would stop working if the repository became private.

## Planned

Near-term work, in the order it should happen:

1. **Hash audit and repair tool** (read-only report first): re-hash every physical object at low priority, report mismatches and duplicate groups with the space they waste, then merge duplicates and fix names in a second, explicit step.
2. **v2-aware delete and trash** for app-uploaded files, so the web app and the apps can delete them safely.
3. **Unique `(source_id, original_path)`** index, after a cleanup pass.
4. **Rebuild the web timeline from the vault**: backfill + stale-row removal in one guarded command with a backup.
5. **Mac app tests in CI** on every build (they need full Xcode, not just Command Line Tools), and a build check that the app is stamped with a macOS 26+ SDK so it keeps the Liquid Glass look (see [Mac app](../08-mac-app.md)).
6. **pillow-heif upgrade** (≥ 1.8 is ~30x faster for HEIC thumbnails) once it is confirmed to run on the Core 2 Duo (no AVX): `./synaps doctor` checks HEIC decoding.

## Ideas

Not scheduled; kept here so they aren't lost.

Synaps is used by one family, so ideas are ranked with that in mind: keeping the photos safe comes first, then making the apps easy for family members, then the nice-to-haves. Features for scale or public sharing matter much less.

**Data safety** (the NAS is a single disk in a 15-year-old PC holding the only copy)
- Off-site backup of the vault for disaster recovery: a nightly encrypted copy (restic or rclone) to a USB drive, Backblaze B2 / S3, or a relative's house. Show "last backup: 6h ago" in the apps and on the dashboard. *The biggest gap today.*
- Disk health monitoring: read SMART data (`smartctl`) and flag a failing drive or a disk over 85% full. Shown on the stats dashboard (below).
- Scheduled integrity checks: re-hash a slice of the vault every night so the whole vault is verified every few weeks (builds on the hash audit tool under *Planned*).

**Family use**
- Multiple users with separate libraries: one login per family member, a parent account that sees everything. The Mac app's hard-coded identity (`Mirrors/Harsh/Mac`, `mac_harsh`) has to go first. Shared albums, setup without IP addresses and per-person stats all depend on this.
- Shared family albums ("Goa trip 2026") that anyone can add to and everyone sees (the v2 schema already has `albums` / `album_items`), plus smart collections
- Zero-config setup: the apps discover the NAS through the `_synaps._tcp` Bonjour service it already advertises, so family members never type an address
- "Free up space" on the iPhone: delete photos that are confirmed on the NAS, after a confirmation step
- Save back to the phone: download a photo or video from the NAS into the iPhone's Photos library
- Expiring private share links for sending an album to relatives who don't use the NAS
- Android client (only if someone in the family uses Android)

**Away from home**
- Remote access through Tailscale: browse and back up from anywhere without exposing the NAS to the internet
- Backup over mobile data on trips, with a size limit or a "photos only, no videos" option

**Photos**
- "On this day" memories as a home-screen widget or a daily notification
- Map view from GPS metadata
- Visual duplicate and burst detection (perceptual hashes), not just identical bytes, with a suggestion of which shot to keep

**Search and intelligence** (local only, must fit 2 GB of RAM or run on the Mac)
- Semantic search ("sunset at the beach", "birthday cake") with local embeddings
- Face grouping ("show me Mom"); OCR for screenshots and documents

**Monitoring and convenience**
- Stats dashboard as the web app's home page: CPU, RAM, temperature, disk, network, backup history per device, and problems that need attention. Being planned now (October 2026); see [stats dashboard plan](stats-dashboard-plan.md).
- Stale-backup warnings: "Mom's iPhone hasn't backed up in 7 days" (on the dashboard first; notifications later)
- Storage breakdown: space used per person and per type (photos, videos, files), and how much deduplication saves
- Scheduled Mac backups (nightly, or when a watched folder changes) instead of clicking Sync
- Scan progress reporting and scheduled incremental scans
- Real-time updates to the web app (WebSocket) when uploads land

**Mac app** (noticed while adding Cancel sync, October 2026)
- Resume a cancelled or interrupted sync from where it stopped instead of re-checking every file
- Cancel for iPhone USB imports, matching Cancel for NAS syncs
- Folder sync still scans the folder on the main thread (`syncItem` / `syncSelectedItems` call `scanDirectoryRecursively` synchronously), which freezes the window on large folders
- The bottom bar gets crowded during a sync (progress, speed, Cancel, zoom, two "Syncing..." buttons); hide the Sync buttons while syncing
- Per-file upload progress and a time-remaining estimate for large files
