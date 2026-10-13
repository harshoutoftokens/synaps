"""
Synaps Physical Storage & Hardlink Mirror Engine.
Handles canonical physical file placement and native hardlink mirror generation.

Durability: an upload is written to STORAGE_PATH/.synaps_tmp, fsynced, renamed into
Vault/ (same filesystem, so the rename is atomic) and the directory is fsynced, all
before the database row that points at it is committed.
"""
import os
import re
import time
import uuid
import errno
import shutil
import hashlib
import logging
import threading
from datetime import datetime
from typing import Iterable, List, Optional, Tuple

from config import STORAGE_PATH, MIRROR_OWNER

logger = logging.getLogger("synaps.storage_engine")

STAGING_DIRNAME = ".synaps_tmp"
COPY_CHUNK_SIZE = 1024 * 1024
HEAD_HASH_BYTES = 65536  # scanner.compute_file_hash() hashes the first 64 KB


def get_storage_path() -> str:
    return STORAGE_PATH


def get_vault_root() -> str:
    p = os.path.join(get_storage_path(), "Vault")
    os.makedirs(p, exist_ok=True)
    return p


def get_mirrors_root() -> str:
    p = os.path.join(get_storage_path(), "Mirrors")
    os.makedirs(p, exist_ok=True)
    return p


def get_staging_root() -> str:
    p = os.path.join(get_storage_path(), STAGING_DIRNAME)
    os.makedirs(p, exist_ok=True)
    return p


def init_storage_directories():
    """Ensure storage base directories exist."""
    get_vault_root()
    get_mirrors_root()
    get_staging_root()


def sanitize_filename(filename: str) -> str:
    """Sanitize filename to prevent directory traversal and illegal characters."""
    name = os.path.basename(filename)
    # Remove null bytes, control chars, and path delimiters
    name = re.sub(r'[\x00-\x1f\\/:"*?<>|]', '_', name)
    if name in (".", ".."):
        name = ""
    return name or "unnamed_file"


def get_canonical_relative_path(capture_date: Optional[datetime], sha256: str, original_filename: str) -> str:
    """
    Generate canonical storage relative path:
    Vault/YYYY/MM/<sha256[:16]>_<clean_name>
    """
    dt = capture_date or datetime.now()
    year_str = f"{dt.year:04d}"
    month_str = f"{dt.month:02d}"

    clean_name = sanitize_filename(original_filename)
    prefix = sha256[:16]
    stored_filename = f"{prefix}_{clean_name}"

    return os.path.join("Vault", year_str, month_str, stored_filename)


def _safe_path_parts(path: str) -> List[str]:
    """Split a client-supplied relative path into components that cannot leave their root:
    empty, "." and ".." components are dropped and NUL bytes replaced."""
    return [
        part.replace("\x00", "_")
        for part in path.replace("\\", "/").split("/")
        if part not in ("", ".", "..")
    ]


def normalize_source_path_for_mirror(original_path: str, platform: str) -> str:
    """
    Converts a source path (Mac, Windows, iOS) into a safe relative mirror path.
    Example:
      Windows 'E:\\Himachal\\2025\\IMG001.jpg' -> 'E/Himachal/2025/IMG001.jpg'
      Mac '/Users/harshrathod/Downloads/AWS/doc.pdf' -> 'Downloads/AWS/doc.pdf'
      iOS 'Camera Roll/IMG_1234.HEIC' -> 'Camera Roll/IMG_1234.HEIC'
    "..", "." and empty components are dropped, so the result never climbs out of
    the mirror folder (ordinary paths map exactly as before).
    """
    norm = original_path.replace("\\", "/").strip("/")

    if platform.lower() == "windows":
        drive_match = re.match(r"^([a-zA-Z]):/(.*)$", norm)
        if drive_match:
            drive, rest = drive_match.groups()
            norm = os.path.join(drive.upper(), rest)

    elif platform.lower() in ("macos", "darwin"):
        user_match = re.match(r"^Users/[^/]+/(.*)$", norm)
        if user_match:
            norm = user_match.group(1)

    parts = _safe_path_parts(norm)
    return os.path.join(*parts) if parts else ""


def get_mirror_base_for_source(source_id_or_name: str, platform: str) -> str:
    s = (source_id_or_name or "").lower()
    p = (platform or "").lower()
    owner = sanitize_filename(MIRROR_OWNER)
    if "mac" in s or "mac" in p or "darwin" in p:
        return os.path.join(owner, "Mac")
    elif "iphone" in s or "ios" in s:
        return os.path.join(owner, "Iphone")
    elif "gdrive" in s or "google" in s:
        return os.path.join(owner, "GoogleDrive")
    elif "laptop" in s or "hp" in s:
        return "Windows_laptop-HP"
    elif "pc" in s or "win" in s:
        return "windows-pc"
    else:
        return sanitize_filename(source_id_or_name)


def _is_within(root_real: str, path: str) -> bool:
    """True if `path` (symlinks resolved) is `root_real` or inside it."""
    try:
        return os.path.commonpath([root_real, os.path.realpath(path)]) == root_real
    except ValueError:
        return False


def fsync_dir(path: str):
    """Persist a directory entry change (rename/link/create). Best effort."""
    try:
        fd = os.open(path, os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def create_hardlink_mirror(physical_full_path: str, source_friendly_name: str, original_path: str, platform: str) -> Optional[str]:
    """
    Creates a zero-byte filesystem hardlink on the NAS disk inside Mirrors/
    so Finder / Windows Explorer can browse the original hierarchy over Samba natively.
    Falls back to symlink if cross-device hardlinks are prohibited.

    original_path comes from the client, so the result is confined to the mirrors root:
    traversal components are dropped and the resolved parent directory is checked, before
    anything is created, replaced or removed. Returns None if no mirror could be made.
    """
    mirror_base = get_mirror_base_for_source(source_friendly_name, platform)
    rel_mirror_path = normalize_source_path_for_mirror(original_path, platform)
    parts = _safe_path_parts(mirror_base) + _safe_path_parts(rel_mirror_path)
    if not rel_mirror_path or len(parts) < 2:
        logger.warning(f"No usable mirror path for {original_path!r}")
        return None

    mirrors_root = get_mirrors_root()
    mirrors_root_real = os.path.realpath(mirrors_root)
    full_mirror_path = os.path.join(mirrors_root, *parts)
    mirror_dir = os.path.dirname(full_mirror_path)

    # Resolve the deepest existing ancestor: a symlinked folder inside Mirrors/ must not
    # lead makedirs (or the link below) outside of it.
    probe = mirror_dir
    while not os.path.lexists(probe) and len(probe) > len(mirrors_root):
        probe = os.path.dirname(probe)
    if not _is_within(mirrors_root_real, probe):
        logger.warning(f"Refusing mirror outside {mirrors_root}: {full_mirror_path}")
        return None

    try:
        os.makedirs(mirror_dir, exist_ok=True)
    except OSError as e:
        logger.warning(f"Cannot create mirror folder {mirror_dir}: {e}")
        return None
    if not _is_within(mirrors_root_real, mirror_dir):
        logger.warning(f"Refusing mirror outside {mirrors_root}: {full_mirror_path}")
        return None

    # If mirror already exists and points to the same file, do nothing
    if os.path.lexists(full_mirror_path):
        if os.path.isdir(full_mirror_path) and not os.path.islink(full_mirror_path):
            logger.warning(f"Mirror path is a folder, not replacing it: {full_mirror_path}")
            return None
        try:
            src_stat = os.stat(physical_full_path)
            dst_stat = os.stat(full_mirror_path)
            if src_stat.st_ino == dst_stat.st_ino and src_stat.st_dev == dst_stat.st_dev:
                return full_mirror_path
        except OSError:
            pass

    # Link under a temporary hidden name, then atomically rename over the old entry (if any),
    # so the mirror never disappears and a stale link is replaced in one step.
    tmp_path = os.path.join(mirror_dir, f".{uuid.uuid4().hex}.synaps-link")
    try:
        # Preferred: zero-byte hardlink
        os.link(physical_full_path, tmp_path)
    except OSError as e:
        logger.warning(f"Hardlink creation failed ({e}), attempting symlink fallback: {full_mirror_path}")
        try:
            # Fallback: relative symlink
            rel_src = os.path.relpath(physical_full_path, mirror_dir)
            os.symlink(rel_src, tmp_path)
        except OSError as sym_err:
            logger.error(f"Mirror link creation failed completely: {sym_err}")
            return None
    try:
        os.replace(tmp_path, full_mirror_path)
    except OSError as e:
        logger.error(f"Mirror link creation failed: {full_mirror_path}: {e}")
        try:
            os.remove(tmp_path)
        except OSError:
            pass
        return None
    logger.debug(f"Created hardlink mirror: {full_mirror_path} -> {physical_full_path}")
    return full_mirror_path


class StagedUpload:
    """
    A partial upload in STORAGE_PATH/.synaps_tmp, SHA-256 hashed while it is written,
    so every received byte is written to disk once and read zero times.
    The staging file keeps the upload's extension (EXIF/ffprobe date extraction picks
    the parser by extension). Writes may come from a worker thread while the request
    handler cleans up, hence the lock.
    """

    def __init__(self, original_filename: str = "", full_md5: bool = False):
        ext = os.path.splitext(original_filename)[1].lower()
        if not re.fullmatch(r"\.[a-z0-9]{1,10}", ext):
            ext = ""
        self.path = os.path.join(get_staging_root(), f"{uuid.uuid4().hex}.upload{ext}")
        self.size = 0
        self.sha256: Optional[str] = None
        self.head_md5: Optional[str] = None  # = scanner.compute_file_hash() of the content
        self.md5: Optional[str] = None  # whole-file MD5, only with full_md5=True (v1 sync records)
        # (canonical_rel, canonical_full, moved_by_us) once the file has been placed in the Vault
        self.placed: Optional[Tuple[str, str, bool]] = None
        self._sha = hashlib.sha256()
        self._head = hashlib.md5()
        self._md5 = hashlib.md5() if full_md5 else None
        self._lock = threading.Lock()
        self._fh = open(self.path, "xb", buffering=COPY_CHUNK_SIZE)

    def _write(self, data: bytes):
        self._sha.update(data)
        if self._md5 is not None:
            self._md5.update(data)
        if self.size < HEAD_HASH_BYTES:
            self._head.update(data[: HEAD_HASH_BYTES - self.size])
        self._fh.write(data)
        self.size += len(data)

    def write(self, data: bytes):
        with self._lock:
            self._write(data)

    def write_chunks(self, chunks: Iterable[bytes]):
        with self._lock:
            for chunk in chunks:
                self._write(chunk)

    def copy_from(self, fileobj, chunk_size: int = COPY_CHUNK_SIZE):
        """Copy (and hash) a whole file object into the staging file."""
        while True:
            chunk = fileobj.read(chunk_size)
            if not chunk:
                break
            self.write(chunk)

    def finish(self) -> str:
        """Flush + fsync + close; returns the lowercase hex SHA-256 of everything written."""
        with self._lock:
            self._fh.flush()
            os.fsync(self._fh.fileno())
            self._fh.close()
            self.sha256 = self._sha.hexdigest()
            self.head_md5 = self._head.hexdigest()
            if self._md5 is not None:
                self.md5 = self._md5.hexdigest()
            return self.sha256

    def discard(self):
        """Remove the staging file if it is still there (no-op once it was moved into the Vault)."""
        with self._lock:
            if not self._fh.closed:
                try:
                    self._fh.close()
                except OSError:
                    pass
            try:
                os.remove(self.path)
            except FileNotFoundError:
                pass
            except OSError as e:
                logger.warning(f"Could not remove staging file {self.path}: {e}")


def sha256_of_file(path: str, chunk_size: int = COPY_CHUNK_SIZE) -> str:
    hasher = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(chunk_size)
            if not chunk:
                break
            hasher.update(chunk)
    return hasher.hexdigest()


def _makedirs_tracked(path: str) -> List[str]:
    """os.makedirs that returns the directories it created (outermost first)."""
    missing = []
    probe = path
    while probe and not os.path.isdir(probe):
        missing.append(probe)
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    os.makedirs(path, exist_ok=True)
    return list(reversed(missing))


def place_in_vault(temp_file_path: str, canonical_rel_path: str, expected_sha256: Optional[str] = None) -> Tuple[str, int, bool]:
    """
    Move a fully written, fsynced staging file to its canonical Vault path and persist the
    rename. If the canonical file already exists (an earlier attempt, or a file whose DB row
    was lost) it is reused only when its content matches `expected_sha256`; a damaged one
    (e.g. truncated by a power cut) is replaced.
    Returns (canonical_full_path, file_size, moved) - moved is False when an existing file
    was reused and the staging file deleted.
    """
    canonical_full_path = os.path.join(get_storage_path(), canonical_rel_path)
    dest_dir = os.path.dirname(canonical_full_path)
    created_dirs = _makedirs_tracked(dest_dir)

    if os.path.exists(canonical_full_path):
        try:
            same = expected_sha256 is None or (
                os.path.getsize(canonical_full_path) == os.path.getsize(temp_file_path)
                and sha256_of_file(canonical_full_path) == expected_sha256
            )
        except OSError:
            same = False
        if same:
            try:
                os.remove(temp_file_path)
            except OSError:
                pass
            return canonical_full_path, os.path.getsize(canonical_full_path), False
        logger.warning(f"Existing canonical file does not match SHA-256 {expected_sha256}, replacing: {canonical_full_path}")

    try:
        # Atomic rename on the same filesystem
        os.replace(temp_file_path, canonical_full_path)
    except OSError as e:
        if e.errno != errno.EXDEV:
            raise
        # Vault on another filesystem than .synaps_tmp: copy, then make the copy durable
        shutil.move(temp_file_path, canonical_full_path)
        with open(canonical_full_path, "rb") as f:
            os.fsync(f.fileno())

    fsync_dir(dest_dir)
    for created in created_dirs:
        fsync_dir(os.path.dirname(created))
    return canonical_full_path, os.path.getsize(canonical_full_path), True


def store_staged_file(temp_file_path: str, capture_date: Optional[datetime], computed_sha256: str, original_filename: str) -> Tuple[str, str, int]:
    """
    Atomically moves a verified temp upload file into the canonical Vault storage.
    Returns: (canonical_rel_path, canonical_full_path, file_size)
    """
    init_storage_directories()
    canonical_rel_path = get_canonical_relative_path(capture_date, computed_sha256, original_filename)
    canonical_full_path, file_size, _ = place_in_vault(temp_file_path, canonical_rel_path, computed_sha256)
    return canonical_rel_path, canonical_full_path, file_size


# link() errors that mean "no hardlink here", not "something is wrong": another filesystem,
# fs.protected_hardlinks (file owned by another user, e.g. dropped in over Samba), exFAT...
_NO_HARDLINK_ERRNOS = (errno.EXDEV, errno.EPERM, errno.EMLINK, errno.ENOTSUP, errno.EOPNOTSUPP)


def _copy_into(src_path: str, fd: int):
    with open(src_path, "rb") as fsrc, os.fdopen(fd, "wb", closefd=False) as fdst:
        shutil.copyfileobj(fsrc, fdst, COPY_CHUNK_SIZE)
        fdst.flush()
        os.fsync(fdst.fileno())


def claim_unique_path(src_path: str, dest_dir: str, filename: str) -> str:
    """
    Move src_path into dest_dir as `filename`, or `name_1.ext`, `name_2.ext`, ... if taken.
    Never overwrites: the name is claimed atomically with link(), or - where a hardlink isn't
    possible - with an exclusive create that the file is then renamed over (or, across
    filesystems, copied into). Returns the final path.
    """
    os.makedirs(dest_dir, exist_ok=True)
    base, ext = os.path.splitext(filename)
    for counter in range(0, 100000):
        name = filename if counter == 0 else f"{base}_{counter}{ext}"
        dest = os.path.join(dest_dir, name)
        try:
            os.link(src_path, dest)
            link_error = None
        except FileExistsError:
            continue
        except OSError as e:
            if e.errno not in _NO_HARDLINK_ERRNOS:
                raise
            link_error = e.errno

        if link_error is None:
            os.remove(src_path)
        else:
            try:
                fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            except FileExistsError:
                continue
            renamed = False
            try:
                if link_error != errno.EXDEV:
                    try:
                        os.replace(src_path, dest)  # same filesystem: rename over our placeholder
                        renamed = True
                    except OSError as e:
                        if e.errno != errno.EXDEV:
                            raise
                if not renamed:
                    _copy_into(src_path, fd)
                    try:
                        shutil.copystat(src_path, dest)  # keep mtime: date fallback for files without EXIF
                    except OSError:
                        pass
                    os.remove(src_path)
            except BaseException:
                if not renamed:
                    try:
                        os.remove(dest)  # our placeholder / partial copy
                    except OSError:
                        pass
                raise
            finally:
                os.close(fd)
        fsync_dir(dest_dir)
        return dest
    raise FileExistsError(f"No free file name for {filename} in {dest_dir}")


# Partial uploads: "<uuid>.upload" (older code) and "<uuid hex>.upload.<ext>" (StagedUpload)
_STAGING_FILE_RE = re.compile(r".+\.upload(\.[a-z0-9]{1,10})?")


def sweep_stale_staging(max_age_seconds: float = 6 * 3600) -> int:
    """Delete partial uploads in STORAGE_PATH/.synaps_tmp that nobody has written to for
    max_age_seconds (left behind by crashes or killed connections). Only *.upload[.ext]
    files directly in that folder are touched. Returns the number of files removed."""
    root = os.path.join(get_storage_path(), STAGING_DIRNAME)
    if not os.path.isdir(root):
        return 0
    removed = 0
    cutoff = time.time() - max_age_seconds
    with os.scandir(root) as entries:
        for entry in entries:
            if not _STAGING_FILE_RE.fullmatch(entry.name):
                continue
            try:
                if entry.is_file(follow_symlinks=False) and entry.stat(follow_symlinks=False).st_mtime < cutoff:
                    os.remove(entry.path)
                    removed += 1
            except OSError as e:
                logger.warning(f"Could not remove stale staging file {entry.path}: {e}")
    return removed
