# Maintenance scripts

One-off and occasional tools for the NAS. None of them run automatically; the server never imports them.
Run them from the `backend/` directory with the backend's virtualenv, for example:

```bash
cd ~/nas_dashboard/backend
venv/bin/python scripts/preheat_thumbnails.py --limit 500
```

Scripts that move files or delete rows preview first (`--dry-run`, or a dry run unless you pass `--execute`).
Back up `synaps.db` first (`./synaps update` keeps automatic backups in `backend/.deploy/backups/`).

| Script | What it does | Changes data? |
|---|---|---|
| `preheat_thumbnails.py` | Generates missing thumbnails ahead of time, newest folders first (`--path`, `--limit`, `--workers`, `--delay`) | Writes thumbnails only |
| `audit_duplicates.py` | Finds byte-identical duplicates in the timeline catalog by SHA-256 and writes `duplicates_report.txt` in the repo root | Saves computed `content_hash` values; files untouched |
| `clean_stale_records.py` | Removes timeline rows whose file no longer exists; refuses to run if storage looks unmounted (`--dry-run` / `--execute`) | Database rows |
| `migrate_hashes.py` | Adds the `content_hash` / `hash_algorithm` columns to an old database | Database schema |
| `move_old_media.py` | Moves pre-iPhone photos from old year folders into one flat `Old_Photos/` folder (`--dry-run` / `--execute`, `--cutoff`, `--path`). Always pass `--path`: without it the whole storage root is used | Files and database paths |
| `organize_existing_media.py` | Sorts flat iPhone media into `YYYY/MM/` folders using the scanner's date logic (`--dry-run` / `--execute`, `--no-db`, `--path`). Always pass `--path`: without it the whole storage root is used | Files and database paths |
| `restructure_nas_mirrors.py` | One-time migration that consolidated the vault into `Vault/YYYY/MM/` and rebuilt `Mirrors/` (dry run unless `--execute`) | Files and database |
| `copy_sample_media.py` | Copies a small sample of real media into `mock_storage/` for local development. `--dest` is relative to the current directory, so pass an absolute path or run it from the repo root | Copies files |

See [docs/12-operations.md](../../docs/12-operations.md) for when to use them.
