"""
Synaps Configuration

Every user/host specific value can be overridden with a SYNAPS_* environment
variable (or a backend/.env file, see .env.example). The defaults reproduce the
original single-user layout, so existing installs keep their paths.
"""
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()


def _env_list(name: str) -> list:
    """Comma-separated env var -> list of non-empty, stripped entries."""
    return [part.strip() for part in os.getenv(name, "").split(",") if part.strip()]


# Base paths
BASE_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = BASE_DIR.parent

# Storage path - on NAS this would be /storage, locally use mock_storage
STORAGE_PATH = os.getenv("SYNAPS_STORAGE_PATH", str(PROJECT_ROOT / "mock_storage"))

# Owner name used in the per-person folders (Vault/<Owner>/..., Mirrors/<Owner>/...)
OWNER_NAME = os.getenv("SYNAPS_OWNER_NAME", "Harsh")
# Top-level folder for the v2 hardlink mirrors of Mac/iPhone/Google Drive sources
MIRROR_OWNER = os.getenv("SYNAPS_MIRROR_OWNER", OWNER_NAME)

# Whitelist directories for media timeline (if empty, entire Vault is scanned)
ALLOWED_SCAN_PATHS = [
    STORAGE_PATH
]

# Blacklist directories that should be skipped during scanning
# Paths should be relative to STORAGE_PATH
EXCLUDED_PATHS = [
    "Vault/Windows_laptop-HP",
    f"Vault/{OWNER_NAME}/Mac/Private",
    # v2 hardlink mirrors: same inodes as the canonical Vault files, would show up twice
    "Mirrors",
    # v2 partial uploads (staging area)
    ".synaps_tmp",
    # trash fallback on the storage disk (routers/trash.py)
    ".synaps_trash",
] + _env_list("SYNAPS_EXCLUDED_PATHS")

# Database
DATABASE_URL = os.getenv("SYNAPS_DB_URL", f"sqlite:///{BASE_DIR / 'synaps.db'}")
# How long a SQLite writer waits for another writer before failing with "database is locked"
SQLITE_BUSY_TIMEOUT_MS = int(os.getenv("SYNAPS_SQLITE_BUSY_TIMEOUT_MS", "30000"))

# Thumbnail cache
THUMBNAIL_DIR = os.getenv("SYNAPS_THUMBNAIL_DIR", str(BASE_DIR / "thumbnails"))
THUMBNAIL_SIZE = (320, 320)
THUMBNAIL_QUALITY = 75

# Trash
TRASH_DIR = os.getenv("SYNAPS_TRASH_DIR", str(BASE_DIR / "trash"))
TRASH_RETENTION_DAYS = 30

# Media extensions
IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".heic"}
VIDEO_EXTENSIONS = {".mp4", ".mov"}
DOCUMENT_EXTENSIONS = set()
RAW_EXTENSIONS = set()

ALL_MEDIA_EXTENSIONS = IMAGE_EXTENSIONS | VIDEO_EXTENSIONS
ALL_EXTENSIONS = ALL_MEDIA_EXTENSIONS | DOCUMENT_EXTENSIONS

# Server
HOST = os.getenv("SYNAPS_HOST", "0.0.0.0")
PORT = int(os.getenv("SYNAPS_PORT", "8000"))

# Security
# Opt-in shared secret for every /api/* request (see main.APITokenMiddleware).
# Empty = no auth. Read at request time, so it can be changed in tests.
API_TOKEN = os.getenv("SYNAPS_API_TOKEN", "").strip()

# CORS. The web app is same-origin (Next rewrites, or the static export served by this
# backend) except for direct uploads from the `next start` dashboard on :3000 to :8000,
# which send the synaps_token cookie; the native apps are not browsers. So by default only
# the dashboard on port 3000 of a LAN/localhost address may make credentialed requests:
# localhost, 127.x, 10.x, 172.16-31.x, 192.168.x, Tailscale 100.64/10 and *.local names.
# SYNAPS_CORS_ORIGINS (comma-separated exact origins) replaces that default; "*" there means
# any origin, but then without credentials. SYNAPS_CORS_ORIGIN_REGEX sets the pattern
# explicitly (empty = none).
CORS_ORIGINS = _env_list("SYNAPS_CORS_ORIGINS")
DEFAULT_CORS_ORIGIN_REGEX = (
    r"https?://("
    r"localhost|127(\.\d{1,3}){3}|\[::1\]"
    r"|10(\.\d{1,3}){3}|192\.168(\.\d{1,3}){2}|172\.(1[6-9]|2\d|3[01])(\.\d{1,3}){2}"
    r"|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])(\.\d{1,3}){2}"
    r"|[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.local"
    r"):3000"
)
CORS_ORIGIN_REGEX = os.getenv(
    "SYNAPS_CORS_ORIGIN_REGEX", "" if CORS_ORIGINS else DEFAULT_CORS_ORIGIN_REGEX
)

# Optional: directory with a static export of the web app (next build with output: 'export').
# When set and present, the backend serves it at "/" so the Node server is not needed.
FRONTEND_DIST = os.getenv("SYNAPS_FRONTEND_DIST", "").strip()

# Uploads: refuse a streamed upload that would leave less than this much free space
MIN_FREE_BYTES = int(os.getenv("SYNAPS_MIN_FREE_BYTES", str(512 * 1024 * 1024)))

# System metrics for the stats dashboard (system_metrics.py): CPU, memory, temperature,
# network and disk are sampled every METRICS_INTERVAL_SECONDS (0 = sampler off), kept per
# minute for a day and as hourly averages for METRICS_HOURLY_RETENTION_DAYS.
METRICS_INTERVAL_SECONDS = int(os.getenv("SYNAPS_METRICS_INTERVAL", "60"))
METRICS_HOURLY_RETENTION_DAYS = int(os.getenv("SYNAPS_METRICS_RETENTION_DAYS", "30"))

# Sync target
SYNC_TARGET_DIR = os.getenv(
    "SYNAPS_SYNC_TARGET_DIR", os.path.join(STORAGE_PATH, "Vault", OWNER_NAME, "Iphone")
)

# Import Manager
IMPORT_SOURCE_DIR = os.getenv(
    "SYNAPS_IMPORT_SOURCE_DIR", os.path.join(STORAGE_PATH, "Imports", OWNER_NAME.lower(), "Iphone")
)
IMPORT_DEST_BASE = os.getenv(
    "SYNAPS_IMPORT_DEST_DIR", os.path.join(STORAGE_PATH, "Vault", OWNER_NAME, "Iphone")
)
IMPORT_OLD_PHOTOS_CUTOFF = 2024  # Dates before this year → Old_Photos/

# Scanner settings
SCAN_BATCH_SIZE = 100
MAX_CONCURRENT_THUMBNAILS = 2  # Low for Core2Duo

# Timeline Settings
ARCHIVE_CUTOFF_YEAR = 2024  # Media taken before this year automatically goes to "Old Photos" in Timeline

# Source Mapping
# Maps the root Vault folder names to a normalized internal source identifier
SOURCE_MAPPING = {
    "Iphone": "iphone",
    "Mac": "mac",
    "Windows_laptop-HP": "windows",
}
