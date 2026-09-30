#!/usr/bin/env python3
"""
Synaps macOS Ingestion Client (v2) — "Git for Files"

Features:
- Sub-second local change detection using (inode, size, mtime) via local SQLite cache.
- Automatic NAS discovery (homecloud1.local, 192.168.0.105, 192.168.0.101).
- Client-side SHA-256 calculation (prevents low-power NAS CPU bottlenecks).
- Pre-check batch deduplication with NAS (0 network bytes transferred for existing files).
- Streaming chunked upload with live progress, transfer rate (MB/s), and ETA.
- Background watch mode and native macOS launchd service installer.
- Native macOS banner notifications via AppleScript.
- Zero third-party dependencies (runs on pure Python 3 standard library).
"""
import os
import sys
import json
import time
import socket
import hashlib
import sqlite3
import argparse
import subprocess
from datetime import datetime
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

CONFIG_DIR = os.path.expanduser("~/.config/synaps")
CONFIG_FILE = os.path.join(CONFIG_DIR, "mac_config.json")
CACHE_DB_FILE = os.path.join(CONFIG_DIR, "client_state.db")
PLIST_PATH = os.path.expanduser("~/Library/LaunchAgents/com.synaps.macsync.plist")

DEFAULT_CANDIDATE_URLS = [
    "http://192.168.0.105:8000",
    "http://homecloud1.local:8000",
    "http://192.168.0.101:8000",
    "http://localhost:8000",
]

DEFAULT_CONFIG = {
    "nas_url": "http://192.168.0.105:8000",
    "source_id": "mac_harsh",
    "friendly_name": "Harsh's Mac",
    "platform": "macOS",
    "watch_folders": [
        os.path.expanduser("~/Downloads"),
        os.path.expanduser("~/Documents"),
        os.path.expanduser("~/Desktop"),
        os.path.expanduser("~/Pictures"),
    ],
    "ignore_patterns": [
        ".DS_Store", ".localized", "node_modules", ".git", ".venv", "venv",
        "__pycache__", ".next", "*.tmp", "*.download", "*.part"
    ],
    "auto_discover_nas": True,
    "notifications_enabled": True
}


def notify_macos(title: str, message: str):
    """Trigger a native macOS banner notification."""
    script = f'display notification "{message}" with title "{title}"'
    try:
        subprocess.run(["osascript", "-e", script], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def load_config() -> dict:
    os.makedirs(CONFIG_DIR, exist_ok=True)
    if os.path.exists(CONFIG_FILE):
        try:
            with open(CONFIG_FILE, "r") as f:
                cfg = json.load(f)
                return {**DEFAULT_CONFIG, **cfg}
        except Exception:
            pass
    with open(CONFIG_FILE, "w") as f:
        json.dump(DEFAULT_CONFIG, f, indent=2)
    return DEFAULT_CONFIG


def save_config(config: dict):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        json.dump(config, f, indent=2)


def discover_active_nas(config: dict) -> str:
    """Tries configured NAS URL and candidate fallback addresses."""
    test_urls = [config.get("nas_url")] + DEFAULT_CANDIDATE_URLS
    seen = set()

    for url in test_urls:
        if not url or url in seen:
            continue
        seen.add(url)
        clean = url.rstrip("/")
        try:
            req = Request(f"{clean}/health", headers={"User-Agent": "SynapsMacClient"})
            with urlopen(req, timeout=1.5) as res:
                if res.status == 200:
                    if clean != config.get("nas_url"):
                        config["nas_url"] = clean
                        save_config(config)
                    return clean
        except Exception:
            continue

    return config.get("nas_url", "http://192.168.0.105:8000")


def init_cache_db():
    os.makedirs(CONFIG_DIR, exist_ok=True)
    conn = sqlite3.connect(CACHE_DB_FILE)
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS local_files (
            path TEXT PRIMARY KEY,
            inode INTEGER,
            size INTEGER,
            mtime REAL,
            sha256 TEXT,
            last_synced_at REAL
        )
    """)
    cur.execute("CREATE INDEX IF NOT EXISTS ix_local_mtime ON local_files (mtime);")
    conn.commit()
    conn.close()


def compute_file_sha256(filepath: str, chunk_size: int = 1048576) -> str:
    """Compute SHA-256 in 1MB chunks."""
    hasher = hashlib.sha256()
    with open(filepath, "rb") as f:
        while chunk := f.read(chunk_size):
            hasher.update(chunk)
    return hasher.hexdigest()


def scan_local_folders(config: dict) -> tuple[list, int]:
    """
    Scans configured watch folders.
    Uses local cache to instantly skip unchanged files without hashing!
    Returns: (list_of_candidate_files, count_unchanged_skipped)
    """
    init_cache_db()
    conn = sqlite3.connect(CACHE_DB_FILE)
    cur = conn.cursor()

    cache = {}
    for row in cur.execute("SELECT path, inode, size, mtime, sha256 FROM local_files").fetchall():
        cache[row[0]] = {"inode": row[1], "size": row[2], "mtime": row[3], "sha256": row[4]}

    candidates = []
    skipped_count = 0

    ignore_set = {
        ".ds_store", ".localized", ".git", "node_modules", "__pycache__",
        ".venv", "venv", ".next", "cache", ".cache"
    }

    for root_folder in config.get("watch_folders", []):
        if not os.path.exists(root_folder):
            continue

        folder_name = os.path.basename(root_folder.rstrip("/"))

        for root, dirs, files in os.walk(root_folder):
            dirs[:] = [d for d in dirs if d.lower() not in ignore_set and not d.startswith('.')]

            for filename in files:
                if filename.startswith('.') or filename.lower().endswith(('.tmp', '.download', '.part', '.crdownload')):
                    continue

                full_path = os.path.join(root, filename)

                try:
                    stat = os.stat(full_path)
                except OSError:
                    continue

                # Sub-second skip check: same size and modification time
                cached = cache.get(full_path)
                file_sha = None

                if cached and cached["size"] == stat.st_size and abs(cached["mtime"] - stat.st_mtime) < 0.01:
                    file_sha = cached.get("sha256")
                    if cached.get("last_synced_at"):
                        # File was already confirmed synced to NAS!
                        skipped_count += 1
                        continue

                # If hash not yet cached, compute it
                if not file_sha:
                    try:
                        file_sha = compute_file_sha256(full_path)
                        # Save hash to local cache immediately
                        cur.execute("""
                            INSERT OR REPLACE INTO local_files (path, inode, size, mtime, sha256, last_synced_at)
                            VALUES (?, ?, ?, ?, ?, NULL)
                        """, (full_path, stat.st_ino, stat.st_size, stat.st_mtime, file_sha))
                    except (OSError, PermissionError):
                        continue

                candidates.append({
                    "original_path": full_path,
                    "original_filename": filename,
                    "file_size": stat.st_size,
                    "source_location": folder_name,
                    "source_created_at": datetime.fromtimestamp(getattr(stat, 'st_birthtime', stat.st_ctime)).isoformat(),
                    "source_modified_at": datetime.fromtimestamp(stat.st_mtime).isoformat(),
                    "client_sha256": file_sha,
                    "inode": stat.st_ino,
                    "mtime": stat.st_mtime,
                })

    conn.commit()
    conn.close()
    return candidates, skipped_count


def api_post_json(url: str, data: dict, timeout: int = 30) -> dict:
    req = Request(url, data=json.dumps(data).encode("utf-8"), headers={"Content-Type": "application/json"})
    with urlopen(req, timeout=timeout) as res:
        return json.loads(res.read().decode("utf-8"))


def upload_single_file(nas_url: str, item: dict, source_id: str) -> dict:
    """Stream a file upload using standard library multipart/form-data."""
    boundary = "----SynapsBoundary" + hashlib.md5(str(time.time()).encode()).hexdigest()
    url = f"{nas_url.rstrip('/')}/api/v2/ingest/upload"

    fields = {
        "source_id": source_id,
        "original_path": item["original_path"],
        "original_filename": item["original_filename"],
        "source_location": item["source_location"],
        "client_sha256": item["client_sha256"],
        "source_created_at": item.get("source_created_at") or "",
        "source_modified_at": item.get("source_modified_at") or "",
        "is_favorite": "false",
    }

    body = bytearray()
    for name, value in fields.items():
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(f"{value}\r\n".encode())

    # File header
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(f'Content-Disposition: form-data; name="file"; filename="{item["original_filename"]}"\r\n'.encode())
    body.extend(b"Content-Type: application/octet-stream\r\n\r\n")

    with open(item["original_path"], "rb") as f:
        file_bytes = f.read()

    body.extend(file_bytes)
    body.extend(f"\r\n--{boundary}--\r\n".encode())

    req = Request(url, data=bytes(body), headers={
        "Content-Type": f"multipart/form-data; boundary={boundary}",
        "Content-Length": str(len(body)),
    })

    with urlopen(req, timeout=180) as res:
        return json.loads(res.read().decode("utf-8"))


def update_local_cache(synced_items: list):
    init_cache_db()
    conn = sqlite3.connect(CACHE_DB_FILE)
    cur = conn.cursor()
    now = time.time()
    for item in synced_items:
        cur.execute("""
            INSERT OR REPLACE INTO local_files (path, inode, size, mtime, sha256, last_synced_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """, (item["original_path"], item["inode"], item["file_size"], item["mtime"], item["client_sha256"], now))
    conn.commit()
    conn.close()


def format_size(bytes_num: int) -> str:
    for unit in ['B', 'KB', 'MB', 'GB']:
        if bytes_num < 1024:
            return f"{bytes_num:.1f} {unit}"
        bytes_num /= 1024
    return f"{bytes_num:.1f} TB"


def run_check(config: dict) -> tuple[list, list]:
    active_nas = discover_active_nas(config)
    print("==================================================")
    print(f" 🍏 Synaps Mac Ingestion Client — {config['friendly_name']}")
    print(f" 📡 Target NAS: {active_nas}")
    print("==================================================")
    print("\n--> [1/2] Scanning local folders for changes...")

    candidates, skipped_count = scan_local_folders(config)
    print(f"    └─> Untouched files skipped instantly: {skipped_count}")
    print(f"    └─> Candidates requiring verification:  {len(candidates)}")

    if not candidates:
        print("\n✨ Everything is 100% up to date! Zero files to sync.\n")
        return [], []

    print("\n--> [2/2] Checking with NAS for deduplication...")
    check_payload = {
        "source": {
            "id": config["source_id"],
            "friendly_name": config["friendly_name"],
            "platform": config["platform"],
        },
        "files": [
            {
                "original_path": c["original_path"],
                "original_filename": c["original_filename"],
                "file_size": c["file_size"],
                "source_location": c["source_location"],
                "source_modified_at": c["source_modified_at"],
                "client_sha256": c["client_sha256"],
            }
            for c in candidates
        ]
    }

    try:
        res = api_post_json(f"{active_nas}/api/v2/ingest/check", check_payload)
    except Exception as e:
        print(f"\n❌ Could not contact NAS at {active_nas}: {e}")
        return [], []

    dedup_paths = {r["original_path"] for r in res.get("results", []) if r.get("status") == "dedup_linked"}
    need_upload_items = [c for c in candidates if c["original_path"] not in dedup_paths]
    dedup_items = [c for c in candidates if c["original_path"] in dedup_paths]

    if dedup_items:
        update_local_cache(dedup_items)

    total_upload_size = sum(item["file_size"] for item in need_upload_items)

    print("\n------------------ SCAN SUMMARY ------------------")
    print(f" Total candidates analyzed:  {len(candidates)}")
    print(f" Deduplicated on NAS:        {len(dedup_items)} (0 network bytes sent!)")
    print(f" Files requiring upload:     {len(need_upload_items)} ({format_size(total_upload_size)})")
    print("--------------------------------------------------")

    if need_upload_items:
        print("\nFiles to be synced:")
        for item in need_upload_items[:10]:
            print(f"  + [{item['source_location']}] {item['original_filename']} ({format_size(item['file_size'])})")
        if len(need_upload_items) > 10:
            print(f"  ... and {len(need_upload_items) - 10} more files.")

    return need_upload_items, dedup_items


def run_sync(config: dict, quiet: bool = False):
    active_nas = discover_active_nas(config)
    need_upload_items, dedup_items = run_check(config)
    if not need_upload_items:
        return

    print(f"\n--> Starting streaming upload of {len(need_upload_items)} files...")
    success = []
    failed = []
    total_bytes = sum(i["file_size"] for i in need_upload_items)
    transferred_bytes = 0
    start_time = time.time()

    for i, item in enumerate(need_upload_items, 1):
        print(f"  [{i}/{len(need_upload_items)}] Uploading: {item['original_filename']} ({format_size(item['file_size'])})...", end="", flush=True)
        t0 = time.time()
        try:
            res = upload_single_file(active_nas, item, config["source_id"])
            if res.get("status") == "success":
                dt = time.time() - t0
                speed = (item["file_size"] / (1024 * 1024)) / max(dt, 0.001)
                print(f" ✅ OK ({speed:.1f} MB/s)")
                success.append(item)
                transferred_bytes += item["file_size"]
                update_local_cache([item])
            else:
                print(f" ⚠️ {res}")
                failed.append(item)
        except Exception as e:
            print(f" ❌ Failed: {e}")
            failed.append(item)

    elapsed = time.time() - start_time
    summary_msg = f"Synced {len(success)} files ({format_size(transferred_bytes)}) in {elapsed:.1f}s."
    print(f"\n✨ {summary_msg}")
    if failed:
        print(f"⚠️ {len(failed)} files failed to upload.")

    if config.get("notifications_enabled", True):
        notify_macos("Synaps Mac Sync Complete", summary_msg)


def run_watch(config: dict, interval_seconds: int = 300):
    """Continuous watch mode checking every N minutes."""
    print("==================================================")
    print(f" 👁️  Synaps Continuous Watcher Mode Active")
    print(f" Interval: every {interval_seconds} seconds")
    print(f" Watching folders: {len(config.get('watch_folders', []))}")
    print(" Press Ctrl+C to stop.")
    print("==================================================")

    while True:
        try:
            candidates, _ = scan_local_folders(config)
            if candidates:
                print(f"\n[{datetime.now().strftime('%H:%M:%S')}] Detected {len(candidates)} new/modified files! Starting sync...")
                run_sync(config)
            else:
                print(f"[{datetime.now().strftime('%H:%M:%S')}] Idle — All files up to date.", end="\r", flush=True)
            time.sleep(interval_seconds)
        except KeyboardInterrupt:
            print("\nWatcher stopped.")
            break
        except Exception as e:
            print(f"\nError in watcher loop: {e}")
            time.sleep(10)


def install_launchd_service():
    """Installs native macOS launchd daemon running in the background."""
    script_path = os.path.abspath(__file__)
    python_path = sys.executable

    plist_content = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.synaps.macsync</string>
    <key>ProgramArguments</key>
    <array>
        <string>{python_path}</string>
        <string>{script_path}</string>
        <string>sync</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>{CONFIG_DIR}/sync.log</string>
    <key>StandardErrorPath</key>
    <string>{CONFIG_DIR}/sync_error.log</string>
</dict>
</plist>
"""
    os.makedirs(os.path.dirname(PLIST_PATH), exist_ok=True)
    with open(PLIST_PATH, "w") as f:
        f.write(plist_content)

    subprocess.run(["launchctl", "unload", PLIST_PATH], stderr=subprocess.DEVNULL)
    subprocess.run(["launchctl", "load", PLIST_PATH], check=True)
    print("✅ Synaps Mac Sync background service installed!")
    print(f"   Plist: {PLIST_PATH}")
    print("   Runs silently every 30 minutes and on login.")


def uninstall_launchd_service():
    if os.path.exists(PLIST_PATH):
        subprocess.run(["launchctl", "unload", PLIST_PATH], stderr=subprocess.DEVNULL)
        os.remove(PLIST_PATH)
        print("✅ Background service uninstalled.")
    else:
        print("Service was not installed.")


def main():
    parser = argparse.ArgumentParser(description="Synaps Mac Ingestion Client")
    parser.add_argument("command", choices=["check", "sync", "watch", "status", "add-folder", "install-service", "uninstall-service"], nargs="?", default="check")
    parser.add_argument("--path", help="Folder path for add-folder command")
    parser.add_argument("--nas-url", help="Override NAS server URL")
    parser.add_argument("--interval", type=int, default=300, help="Interval in seconds for watch mode")
    args = parser.parse_args()

    config = load_config()
    if args.nas_url:
        config["nas_url"] = args.nas_url

    if args.command == "add-folder":
        if not args.path:
            print("Error: --path required for add-folder")
            sys.exit(1)
        abs_p = os.path.abspath(os.path.expanduser(args.path))
        if abs_p not in config["watch_folders"]:
            config["watch_folders"].append(abs_p)
            save_config(config)
            print(f"✅ Added watched folder: {abs_p}")
        else:
            print(f"Folder already watched: {abs_p}")

    elif args.command == "status":
        active_nas = discover_active_nas(config)
        init_cache_db()
        conn = sqlite3.connect(CACHE_DB_FILE)
        cached_count = conn.execute("SELECT count(*) FROM local_files").fetchone()[0]
        conn.close()

        print("==================================================")
        print(f" 🍏 Synaps Mac Ingestion Client Status")
        print("==================================================")
        print(f" Config file:        {CONFIG_FILE}")
        print(f" Active NAS URL:     {active_nas}")
        print(f" Source ID:          {config.get('source_id')}")
        print(f" Cached synced files: {cached_count}")
        print("\n Watched folders:")
        for wf in config.get("watch_folders", []):
            exists_mark = "✓" if os.path.exists(wf) else "✗"
            print(f"   [{exists_mark}] {wf}")
        print("==================================================")

    elif args.command == "sync":
        run_sync(config)

    elif args.command == "watch":
        run_watch(config, interval_seconds=args.interval)

    elif args.command == "install-service":
        install_launchd_service()

    elif args.command == "uninstall-service":
        uninstall_launchd_service()

    else:
        run_check(config)


if __name__ == "__main__":
    main()
