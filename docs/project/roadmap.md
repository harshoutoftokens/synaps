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

**Photos**
- Albums and smart collections in the apps and the web app (the v2 schema already has `albums` / `album_items`)
- Map view from GPS metadata; "On this day" memories
- Visual duplicate detection (perceptual hashes), not just identical bytes

**Search and intelligence** (local only, must fit 2 GB of RAM or run on the Mac)
- Semantic search ("sunset at the beach") with local embeddings
- Face grouping; OCR for screenshots and documents

**System**
- Scan progress reporting and scheduled incremental scans
- Real-time updates to the web app (WebSocket) when uploads land
- Off-site backup of the vault (Backblaze B2 / S3) for disaster recovery
- Android client
- Multiple users with separate libraries
