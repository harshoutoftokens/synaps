# API Reference

Every HTTP endpoint the Synaps backend serves, grouped by router. Built from reading [`backend/main.py`](../backend/main.py) and each file in [`backend/routers/`](../backend/routers/), so the field names, defaults and status codes here are the ones in the code. For how the ingest endpoints fit together, read [03-storage-and-ingest.md](03-storage-and-ingest.md) first.

## Conventions

### Base URL

`http://<nas>:8000`, e.g. `http://homecloud1.local:8000`. The port is `SYNAPS_PORT` (default 8000). When `SYNAPS_FRONTEND_DIST` is set, the same server also serves the web app at `/`; it never answers `/api/*` paths, so an unknown API path stays a JSON 404 and a wrong method stays a 405.

FastAPI's interactive docs are at `/docs` and the schema at `/openapi.json` (both outside `/api/`, so not token-protected). Routes marked "hidden" below are left out of that schema.

### Authentication

Auth is off unless `SYNAPS_API_TOKEN` is set (`APITokenMiddleware` in `main.py`). When set, every request to a path starting with `/api/` must carry the token in one of three ways:

| Where | Form |
|---|---|
| Header | `Authorization: Bearer <token>` |
| Cookie | `synaps_token=<token>` (quotes allowed) |
| Query | `?token=<token>` (for `<img>`/`<video>` URLs; redacted in the access log) |

Exempt: `GET`/`HEAD /api/health`, every `OPTIONS` request (CORS preflight), and every path outside `/api/` (`/health`, the web app, `/docs`). A missing or wrong token gets **401** `{"detail": "unauthorized"}` with `WWW-Authenticate: Bearer`. The token is read per request; comparisons are constant-time.

CORS: by default only port-3000 origins on LAN/localhost/Tailscale/`*.local` addresses may make credentialed requests (`SYNAPS_CORS_ORIGINS` / `SYNAPS_CORS_ORIGIN_REGEX` override it). The native apps are not affected by CORS.

### Errors

Errors use FastAPI's shape: `{"detail": "<message>"}`. Request validation failures (missing or mistyped parameters) are **422** with `detail` as a list of field errors. Unhandled exceptions are a plain 500.

### Caching and ranges

File-serving endpoints go through `cached_file_response()` in [`backend/routers/media.py`](../backend/routers/media.py):

- `ETag` (MD5 of inode, mtime and size), `Last-Modified` and `Cache-Control` are always sent. `If-None-Match` (preferred) or `If-Modified-Since` that still matches returns **304**.
- `Range` requests get **206** with `Content-Range` (Starlette's `FileResponse`), so downloads resume and videos seek.
- `HEAD` is supported where the tables below say so.
- Thumbnails: `Cache-Control: private, max-age=604800` (7 days). Files: `private, max-age=86400` (1 day). Placeholders and "queued" answers: `no-store`.

### Trailing slashes

Routes are defined without a trailing slash. A few collection routes also register the `/` form explicitly (`/api/media/`, `/api/search/`, `/api/trash/`, `/api/settings/`). For every other route, FastAPI's default slash redirect applies: a request with an extra trailing slash gets a **307** redirect to the canonical path, which some clients do not follow for PUT/POST. Always call the paths exactly as listed.

### IDs and dates

v1 ids (`media_files`, `trash_items`, `sync_records`) and v2 ids for physical objects, logical items and albums are UUID strings. `filesystem_nodes.id` is an integer. Source ids are strings the client chooses. Dates are ISO-8601 strings without a time zone.

## Endpoint index

| Router | Prefix | Endpoints |
|---|---|---|
| Core ([`main.py`](../backend/main.py)) | `/api`, `/health` | 3 |
| Media ([`media.py`](../backend/routers/media.py)) | `/api/media` | 7 |
| Finder ([`finder.py`](../backend/routers/finder.py)) | `/api/finder` | 4 |
| Search ([`search.py`](../backend/routers/search.py)) | `/api/search` | 2 |
| Trash ([`trash.py`](../backend/routers/trash.py)) | `/api/trash` | 6 |
| Settings ([`settings.py`](../backend/routers/settings.py)) | `/api/settings` | 3 |
| Sync, v1 uploads ([`sync.py`](../backend/routers/sync.py)) | `/api/sync` | 4 |
| Import ([`imports.py`](../backend/routers/imports.py)) | `/api/import` | 5 |
| Ingest v2 ([`ingest_v2.py`](../backend/routers/ingest_v2.py)) | `/api/v2` | 9 |

43 endpoints in total (aliases counted with their primary route).

---

## Core (`main.py`)

### `GET /api/health` (also `HEAD`, and `GET`/`HEAD /health`)

Liveness check. Always open, even with a token set.

```json
{"status": "ok", "app": "Synaps", "version": "1.0.0", "name": "homecloud1"}
```

`name` is the NAS's host name (`socket.gethostname()` up to the first dot); the apps show it instead of the IP address. `/health` is the same handler outside `/api/`. The `HEAD` routes are hidden.

### `POST /api/scan`

Starts a filesystem scan of the storage root (`scan_directory()` in [`backend/scanner.py`](../backend/scanner.py)) in a background thread. The automatic startup scan is disabled, so this is the only way to trigger one over HTTP. No body.

Response: `{"status": "scan_started"}`, or `{"status": "scan_already_running"}` if one is in progress (only one runs at a time). See [05-scanner-and-timeline.md](05-scanner-and-timeline.md).

---

## Media (`/api/media`)

Reads the v1 `media_files` catalog: the web timeline, viewer and thumbnails. See [06-thumbnails-and-media.md](06-thumbnails-and-media.md).

### `GET /api/media` (aliases `/api/media/`, `/api/media/timeline`)

Paginated media, newest `date_taken` first.

| Query | Type | Default | Notes |
|---|---|---|---|
| `view` | string | `timeline` | `timeline` (grouped by month) or `gallery` (flat) |
| `sources` | string | none | Comma-separated `media_files.source` values, e.g. `iphone,mac` (lowercased) |
| `page` | int ≥ 1 | 1 | |
| `per_page` | int 1–200 | 50 | |
| `media_type` | string | none | `image`, `video`, `document`, or the flags `screenshot`, `screen_recording`, `raw`, `favorite` |
| `year` | int | none | Filters on `date_taken` |
| `month` | int | none | 1–12; with `year` |

Response: `total`, `page`, `per_page`, `total_pages`, plus:

- `view=timeline`: `groups[]` of `{year, month, month_name, items[]}`. Items dated before `ARCHIVE_CUTOFF_YEAR` (2024) go into one group `{year: 0, month: 0, month_name: "Archive"}`. Grouping is done per page, so a month can span pages.
- `view=gallery`: `items[]`, each with an extra `date_string` such as `"16 May 2026"`.

Each item: `id, filename, media_type, extension, file_size, file_size_human, width, height, is_screenshot, is_favorite, date_taken, has_thumbnail, thumbnail_url, file_url`, plus `stream_url` and `duration` for videos.

### `GET /api/media/item/{media_id}`

One item with full detail: the list fields plus `path` (relative), `directory`, `mime_type`, `date_created`, `date_modified`, `camera_make`, `camera_model`, `gps_lat`, `gps_lon`. **404** if unknown.

### `GET /api/media/thumbnail/{media_id}` (also `HEAD`, hidden)

| Outcome | Response |
|---|---|
| Thumbnail cached | `image/webp`, ETag/304 |
| Not generated yet | Enqueued on the background worker; returns an SVG "Generating..." placeholder, `Cache-Control: no-store`, `Retry-After: 2`. The web grid polls with `HEAD` until the content type stops being SVG. |
| Unknown id, file missing on disk, or generation failed earlier | **404** |

### `GET /api/media/file/{media_id}` (also `HEAD`, hidden)

The original file, with Range and 304 support. HEIC/HEIF is served as a cached JPEG preview (longest side at most 2560 px, named `<name>.jpg`) unless `original=true`.

| Query | Type | Default |
|---|---|---|
| `original` | bool | `false` |

Status: **404** unknown id or file missing; **503** `Preview converter busy` with `Retry-After: 5` when the HEIC converter is saturated. If conversion fails for another reason, the original HEIC bytes are served.

### `GET /api/media/stream/{media_id}` (also `HEAD`, hidden)

Same as `/file` without HEIC conversion; meant for video players (Range → 206). **404** as above.

### `POST /api/media/favorite/{media_id}`

Toggles `is_favorite` on the v1 row. Response: `{"id", "is_favorite"}`. **404** if unknown. Does not touch v2 `media_metadata`.

### `GET /api/media/stats`

Library counters from `media_files`: `total_files, images, videos, documents, screenshots, favorites, total_size_bytes, total_size_human`.

---

## Finder (`/api/finder`)

Browses the real directory tree under the storage root. Every `path` parameter is relative to the storage root and goes through `resolve_storage_path()`: a leading `/` means the root, `..` or a NUL byte is **400**, any dot-prefixed component (`.synaps_tmp`, `.synaps_trash`, ...) is **404**, and a path whose real location (after symlinks) is outside the root is **403**.

### `GET /api/finder/browse`

| Query | Type | Default |
|---|---|---|
| `path` | string | `""` (root) |
| `page` | int ≥ 1 | 1 |
| `per_page` | int 1–1000 | 200 |

Folders are always returned in full; only files are paginated (and only the page's files are `stat()`ed). Directory listings are cached for 60 s while the folder's mtime is unchanged.

Response: `current_path` (`"/"` for the root), `breadcrumb[]` of `{name, path}` starting with `Storage`, `folders[]` of `{name, path, type: "folder", children_count, modified}`, `files[]` of `{name, path, type: "file", file_type, extension, mime_type, size, size_human, modified, media_id}`, `total_folders`, `total_files`, `page`, `per_page`. `file_type` is `image`, `video`, `document` or `other`; `media_id` is the `media_files` id when the file is in the timeline, else null.

Status: **404** directory not found, **400** not a directory, **403** permission denied.

### `GET /api/finder/download` (also `HEAD`, hidden)

| Query | Type | Default |
|---|---|---|
| `path` | string | required |

The file with its guessed MIME type and its name as the download filename, plus ETag/304 and Range. **404** missing, **400** not a regular file.

### `GET /api/finder/thumbnail` (also `HEAD`, hidden)

| Query | Type | Default | Notes |
|---|---|---|---|
| `path` | string | required | |
| `size` | any | none | Sent by the iPhone app; accepted and ignored |

| Outcome | Response |
|---|---|
| Thumbnail cached (under this path, a legacy key, the `media_files` record, or the canonical Vault file behind a symlink or `Mirrors/` hardlink) | `image/webp`, ETag/304 |
| Queued or generating | **202** `{"status": "queued"}`, `Retry-After: 2`, `Cache-Control: no-store`. The Mac and iPhone apps poll on this. |
| Extension cannot be thumbnailed | **404** `File type does not support thumbnails` |
| Generation failed recently | **404** `Thumbnail could not be generated` |
| File missing / not a file | **404** / **400** |

Supported extensions: `.jpg .jpeg .png .heic .heif .webp .mov .mp4 .m4v .pdf`. A mirror's thumbnail is generated once under the canonical Vault path and shared.

### `GET /api/finder/tree`

| Query | Type | Default |
|---|---|---|
| `depth` | int 1–4 | 2 |

Folder-only tree: `{"tree": [{name, path, type: "folder", children[]}]}`. Hidden folders and symlinks leading outside the root are skipped; at most 5000 folders; cached for 30 s per depth.

---

## Search (`/api/search`)

Searches the v1 catalog with SQL `LIKE` (ASCII case-insensitive; `%` and `_` in the query are matched literally).

### `GET /api/search` (alias `/api/search/`)

| Query | Type | Default |
|---|---|---|
| `q` | string, 1–200 chars | required |
| `media_type` | string | none |
| `page` | int ≥ 1 | 1 |
| `per_page` | int 1–200 | 50 |

Matches `filename`, `directory` or `relative_path`, newest first. Response: `query, total, page, per_page, results[]` of `{id, filename, directory, media_type, extension, file_size, date_taken, thumbnail_url, file_url}`.

### `GET /api/search/suggestions`

| Query | Type | Default |
|---|---|---|
| `q` | string, 1–200 chars | required |

Response: `{"files": [...up to 5 filenames], "directories": [...up to 5 directories]}`.

---

## Trash (`/api/trash`)

Moves v1 timeline files to a trash folder for 30 days (`TRASH_RETENTION_DAYS`). The file goes to `SYNAPS_TRASH_DIR`, or to `<storage>/.synaps_trash` when that directory is on another filesystem. Expired items are also purged automatically once a day by `main.py`.

### `POST /api/trash/delete/{media_id}`

Moves the file to trash, records a `trash_items` row and deletes the `media_files` row.

Response: `{"status": "success", "message": "<name> moved to trash"}`.

Status: **404** unknown id or file missing; **409** if the file is outside the storage root or belongs to the v2 vault (canonical object, hardlinked, symlink, or under `Mirrors/`; message ends with "it can't be moved to trash from here"); **500** if the move or commit fails (the file is moved back on a failed commit).

### `GET /api/trash` (alias `/api/trash/`)

Response: `total`, `items[]` of `{id, filename, file_size, media_type, deleted_at, auto_delete_at, days_remaining, thumbnail_url}`, newest deletion first.

### `GET /api/trash/thumbnail/{trash_id}` (also `HEAD`, hidden)

The cached WebP thumbnail of the original path (ETag/304), or the SVG placeholder (`no-store`) if none exists. Never enqueues generation. **404** if the trash item is unknown.

### `POST /api/trash/restore/{trash_id}`

Moves the file back and re-indexes it. Never overwrites: if the original path is taken, it is restored as `name (restored).ext`, `name (restored 2).ext`, and so on.

Response: `{"status": "success", "message", "media_id", "restored_filename"}`. `media_id` is the new `media_files` id (or null if indexing skipped it).

Status: **404** item or trash file missing; **409** trash file not inside a trash directory, original location outside the storage root, or no free name; **500** move failed.

### `DELETE /api/trash/permanent/{trash_id}`

Deletes the file (only ever from inside a trash directory) and its thumbnail. Response: `{"status": "success", "message"}`. **404** unknown, **409** file not inside a trash directory, **500** delete failed.

### `POST /api/trash/cleanup`

Purges items whose `auto_delete_at` has passed. Response: `{"status": "success", "deleted": <n>, "errors": <n>}`.

---

## Settings (`/api/settings`)

### `GET /api/settings` (alias `/api/settings/`)

All stored settings plus defaults, and the server's paths (always from config, never from the database):

```json
{"theme": "system", "storage_path": "/storage", "thumbnail_dir": "...", "trash_dir": "..."}
```

### `PUT /api/settings` (alias `/api/settings/`)

JSON object of settings to write. Only `theme` is writable, with values `light`, `dark` or `system`. Unknown or read-only keys, or a bad value, are **400**. Response: `{"status": "success"}`.

### `GET /api/settings/storage-usage`

| Field | Meaning |
|---|---|
| `total_indexed_size`, `total_indexed_human`, `total_files`, `images`, `videos`, `documents` | From `media_files` |
| `thumbnail_cache_size`, `thumbnail_cache_human` | Size of the thumbnail directory |
| `trash_size`, `trash_size_human` | `SYNAPS_TRASH_DIR` plus `.synaps_trash` |
| `disk_total`, `disk_used`, `disk_free` (+ `_human`) | The storage volume (statvfs) |

Folder sizes are computed in a background thread and reused for 10 minutes. Until the first walk finishes, the size is `0` and the `_human` field is `"Calculating…"`.

---

## Sync, v1 uploads (`/api/sync`)

The web dashboard's Sync page upload path. Files land in the v1 layout `SYNAPS_SYNC_TARGET_DIR/YYYY/MM` (by upload date; default `Vault/<Owner>/Iphone`), not in the v2 Vault. The native apps use `/api/v2/ingest/*` instead.

### `POST /api/sync/upload`

Multipart form:

| Field | Type | Default |
|---|---|---|
| `file` | file | required |
| `device` | string | `iPhone` |

Only `.jpg .jpeg .png .heic .mp4 .mov` are accepted. The file is staged, hashed (SHA-256 and MD5), checked for duplicates against `sync_records`, `media_files` and `physical_objects`, then placed under a unique name (`_1`, `_2` on collision), recorded, indexed and queued for a thumbnail.

Responses (both 200):

- New: `{"status": "success", "message", "filename", "path", "size", "media_id"}`
- Duplicate: `{"status": "duplicate", "message": "File already ... as <name>", "filename"}`

Status: **400** no filename or unsupported type; **507** not enough free space (`SYNAPS_MIN_FREE_BYTES`) or disk full; **500** other storage errors.

### `POST /api/sync/upload-batch`

Multipart form with `files` (several file parts) and `device` (default `iPhone`). Files are processed one after another.

Response: `{"total", "success", "duplicates", "errors", "results": [{"filename", "status", "reason"?}]}` where `status` is `success`, `duplicate`, `skipped` (reason `unsupported`) or `error`. Per-file errors do not fail the request.

### `GET /api/sync/history`

| Query | Type | Default |
|---|---|---|
| `page` | int ≥ 1 | 1 |
| `per_page` | int 1–1000 | 50 |

Response: `{"total", "page", "records": [{id, filename, file_size, source_device, synced_at}]}`, newest first.

### `GET /api/sync/check-duplicate`

| Query | Type | Default |
|---|---|---|
| `file_hash` | string | required |

Response: `{"exists": bool}`. Matches `sync_records.file_hash` (whole-file MD5) or `media_files.file_hash` (MD5 of the first 64 KB), so the two kinds of hash are compared against the same value; treat it as a legacy hint.

---

## Import (`/api/import`)

The manual Import Manager ([`backend/import_manager.py`](../backend/import_manager.py)). Source folder `SYNAPS_IMPORT_SOURCE_DIR` (default `Imports/<owner>/Iphone`), destination `SYNAPS_IMPORT_DEST_DIR`. Jobs live in memory and are lost on restart. No request bodies.

### `POST /api/import/scan`

Counts files without reading metadata. Response: `{"total_files", "photos", "videos", "total_size", "total_size_human", "source_dir"}`. **500** with the error message on failure.

### `POST /api/import/preview`

Starts a background job that works out each file's destination. Response: `{"status": "started", "job_id"}`. Poll `/progress/{job_id}`; when complete, the job's `preview_destinations` is `{"destinations": [{"path": "2025/07" | "Old_Photos" | "Unknown_Date", "count"}], "total_files", "unknown_date"}`.

### `POST /api/import/execute`

Starts the import unless one is already running.

- Started: `{"status": "started", "job_id"}`
- Already running: `{"status": "already_running", "job_id", "phase", "progress"}`

### `GET /api/import/progress/{job_id}`

The job: `{job_id, status, phase, progress (0-100), total_files, processed_files, imported, duplicates_skipped, unknown_date, errors, error_log[], preview_destinations, started_at, completed_at}`. `status` is one of `pending`, `scanning`, `importing`, `indexing`, `complete`, `error`. **404** if unknown. The web page polls about every 2 seconds.

### `GET /api/import/latest`

The most recent job in the same shape, or `{"status": "none"}`.

---

## Ingest v2 (`/api/v2`)

Content-addressed ingest used by the Mac and iPhone apps, plus read APIs for the v2 tables. See [03-storage-and-ingest.md](03-storage-and-ingest.md) for the full pipeline.

### `POST /api/v2/ingest/check`

Pre-check a batch: link files whose content is already on the NAS, report which need uploading. JSON body:

```json
{
  "source": {"id": "iphone_harsh", "friendly_name": "Harsh's iPhone", "platform": "iOS", "volume_identifier": null},
  "files": [{
    "original_path": "Camera Roll/IMG_1234.HEIC", "original_filename": "IMG_1234.HEIC",
    "file_size": 2345678, "source_location": "Camera Roll",
    "source_modified_at": "2025-07-01T10:00:00Z", "client_sha256": "<64 hex>", "is_favorite": false
  }]
}
```

`source.platform` is free text (`macOS`, `Windows`, `iOS`); `volume_identifier`, `source_modified_at` and `is_favorite` are optional. The server sets no batch limit; the apps send at most 200 files.

Response:

```json
{"source_id": "iphone_harsh", "total_checked": 1, "need_upload": 1, "dedup_linked": 0,
 "results": [{"original_path": "Camera Roll/IMG_1234.HEIC", "status": "need_upload", "physical_object_id": null}]}
```

`status` is `need_upload` or `dedup_linked` (then `physical_object_id` is set). Side effects: registers or updates the source, creates or re-points logical items and nodes, creates mirror hardlinks.

### `POST /api/v2/ingest/match`

Read-only lookup of `(filename, size)` pairs the NAS already holds, from any source. Body: `{"files": [{"filename": "IMG_1234.HEIC", "size": 2345678}]}`, at most 2000 entries (**413** above). Entries with an empty name or size ≤ 0 are ignored.

Response: `{"matches": [{"filename", "size", "sha256"}]}`, only for pairs found (in `logical_items` joined to `physical_objects`, or in `media_files` rows with a `content_hash`). Servers older than this endpoint answer 404; the apps log it and simply leave those items unmarked.

### `PUT /api/v2/ingest/stream`

Preferred upload. The request body is the raw file; metadata is in the query string.

| Query | Type | Default |
|---|---|---|
| `source_id` | string | required |
| `original_path` | string | required |
| `original_filename` | string | required |
| `source_location` | string | required |
| `client_sha256` | string (64 hex) | required |
| `source_created_at` | ISO-8601 string | none |
| `source_modified_at` | ISO-8601 string | none |
| `is_favorite` | bool | `false` |

Headers: `Content-Length` is required. `Content-Type` is stored as the MIME type unless it is `application/octet-stream`, in which case the type is guessed from the file name.

Response (200):

```json
{"status": "success", "physical_object_id": "<uuid>", "logical_item_id": "<uuid>",
 "canonical_path": "Vault/2025/07/3f9a1c0d2b4e5f60_IMG_1234.HEIC",
 "mirror_path": "/storage/Mirrors/Harsh/Iphone/Camera Roll/IMG_1234.HEIC", "sha256": "<64 hex>"}
```

`canonical_path` is relative to the storage root; `mirror_path` is absolute, or null if no mirror could be made. Uploading content the NAS already has returns the existing object.

| Status | When |
|---|---|
| 400 | Malformed `client_sha256`; invalid `Content-Length`; body longer or shorter than `Content-Length`; client disconnected; `SHA-256 mismatch: client=..., computed=...` |
| 411 | `Content-Length` missing |
| 422 | Missing required query parameter |
| 507 | Free space minus the upload would fall below `SYNAPS_MIN_FREE_BYTES` (default 512 MiB), or the disk filled up while writing |
| 500 | Other storage errors (`Upload stream error: ...`), or a commit that still conflicts after 3 attempts |

A `GET` on this path returns **405**; the Mac app uses that to detect support.

### `POST /api/v2/ingest/upload`

Legacy multipart upload, kept as the fallback when `/ingest/stream` answers 404/405 (the iPhone app also falls back on 411). Form fields: the same names as the stream query parameters, plus the file part `file`. Same response and status codes, except that 411 and the `Content-Length` checks do not apply, and the free-space check runs only when the part size is known.

### `POST /api/v2/ingest/albums` (hidden alias `/api/v2/ingest/sync-albums`)

Adds album memberships. Body: `{"source_id": "iphone_harsh", "album_name": "Somnath Trip", "original_paths": ["Camera Roll/IMG_9821.HEIC"]}`.

Response: `{"album_id", "album_name", "newly_linked_items"}`. Creates the album for that source if needed; paths with no logical item for the source are skipped; existing memberships are left alone and nothing is ever removed. **404** `Source not found`.

`/ingest/sync-albums` is the same handler, left out of the OpenAPI schema; the code comment says it is the path used by the Mac app's `syncAlbums()`, but the current Mac app calls `/ingest/albums`.

### `GET /api/v2/sources`

Response: `{"sources": [{id, friendly_name, platform, volume_identifier, created_at, last_seen_at, total_items}]}`. `total_items` counts the source's logical items.

### `GET /api/v2/sources/{source_id}/tree`

Lists one folder of a device's virtual tree (`filesystem_nodes`) without touching the disk.

| Query | Type | Default |
|---|---|---|
| `parent_id` | int | none (top level) |

Response:

- `source` (as in `/sources`, without `total_items`), `parent_id`
- `breadcrumbs[]` of `{id, name}`, starting with `{id: null, name: <friendly_name>}`
- `folders[]` of `{id, name, type: "folder", children_count}`
- `files[]` of `{id, name, type: "file", physical_object_id, logical_item_id, file_size, media_type, is_favorite, capture_date, sha256, original_path}`
- `total_folders`, `total_files`

Folders first, then by name. **404** `Source not found`. An unknown `parent_id` returns empty lists.

### `GET /api/v2/albums`

Response: `{"albums": [{id, name, source_id, item_count, cover_physical_id, created_at}]}`, sorted by name. `cover_physical_id` is the physical object of the album's first-added item (null for an empty album).

### `GET /api/v2/albums/{album_id}`

Response: `album` (`{id, name, source_id, item_count, created_at}`), `items[]` of `{logical_id, physical_object_id, filename, original_path, file_size, media_type, is_favorite, capture_date}`, `total_items`. **404** `Album not found`.

There is no v2 endpoint that serves file bytes or thumbnails by physical object id. Clients fetch thumbnails with `/api/finder/thumbnail?path=<canonical_path or mirror path>` and files with `/api/finder/download`.

## Gotchas and limits

- **Two catalogs.** `/api/media`, `/api/search` and `/api/trash` read v1 `media_files`; `/api/v2/*` reads the v2 tables. Favorites toggled with `/api/media/favorite` are not written to `media_metadata`.
- **No v2 delete.** App-uploaded files are refused by `/api/trash/delete` with 409, and no other endpoint deletes them.
- **No pagination on v2 reads.** `/api/v2/sources/{id}/tree` returns a whole folder and `/api/v2/albums/{id}` a whole album.
- **Import jobs are in memory.** A backend restart forgets every job id.
- **`/api/sync/check-duplicate` mixes hash kinds** (whole-file MD5 vs first-64-KB MD5), so it can miss.
