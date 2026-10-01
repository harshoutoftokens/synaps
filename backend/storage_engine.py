"""
Synaps Physical Storage & Hardlink Mirror Engine.
Handles canonical physical file placement and native hardlink mirror generation.
"""
import os
import re
import shutil
import hashlib
import logging
from datetime import datetime
from pathlib import Path
from typing import Optional, Tuple

from config import STORAGE_PATH

logger = logging.getLogger("synaps.storage_engine")

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
    p = os.path.join(get_storage_path(), ".synaps_tmp")
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


def normalize_source_path_for_mirror(original_path: str, platform: str) -> str:
    """
    Converts a source path (Mac, Windows, iOS) into a safe relative mirror path.
    Example:
      Windows 'E:\\Himachal\\2025\\IMG001.jpg' -> 'E/Himachal/2025/IMG001.jpg'
      Mac '/Users/harshrathod/Downloads/AWS/doc.pdf' -> 'Downloads/AWS/doc.pdf'
      iOS 'Camera Roll/IMG_1234.HEIC' -> 'Camera Roll/IMG_1234.HEIC'
    """
    norm = original_path.replace("\\", "/").strip("/")

    if platform.lower() == "windows":
        drive_match = re.match(r"^([a-zA-Z]):/(.*)$", norm)
        if drive_match:
            drive, rest = drive_match.groups()
            return os.path.join(drive.upper(), rest)
        return norm

    elif platform.lower() in ("macos", "darwin"):
        user_match = re.match(r"^Users/[^/]+/(.*)$", norm)
        if user_match:
            return user_match.group(1)
        return norm

    return norm


def get_mirror_base_for_source(source_id_or_name: str, platform: str) -> str:
    s = (source_id_or_name or "").lower()
    p = (platform or "").lower()
    if "mac" in s or "mac" in p or "darwin" in p:
        return os.path.join("Harsh", "Mac")
    elif "iphone" in s or "ios" in s:
        return os.path.join("Harsh", "Iphone")
    elif "gdrive" in s or "google" in s:
        return os.path.join("Harsh", "GoogleDrive")
    elif "laptop" in s or "hp" in s:
        return "Windows_laptop-HP"
    elif "pc" in s or "win" in s:
        return "windows-pc"
    else:
        return sanitize_filename(source_id_or_name)


def create_hardlink_mirror(physical_full_path: str, source_friendly_name: str, original_path: str, platform: str) -> Optional[str]:
    """
    Creates a zero-byte filesystem hardlink on the NAS disk inside Mirrors/
    so Finder / Windows Explorer can browse the original hierarchy over Samba natively.
    Falls back to symlink if cross-device hardlinks are prohibited.
    """
    mirror_base = get_mirror_base_for_source(source_friendly_name, platform)
    rel_mirror_path = normalize_source_path_for_mirror(original_path, platform)
    full_mirror_path = os.path.join(get_mirrors_root(), mirror_base, rel_mirror_path)

    os.makedirs(os.path.dirname(full_mirror_path), exist_ok=True)

    # If mirror already exists and points to the same file, do nothing
    if os.path.lexists(full_mirror_path):
        try:
            src_stat = os.stat(physical_full_path)
            dst_stat = os.stat(full_mirror_path)
            if src_stat.st_ino == dst_stat.st_ino and src_stat.st_dev == dst_stat.st_dev:
                return full_mirror_path
        except OSError:
            pass
        # Remove existing file/link to update
        try:
            os.remove(full_mirror_path)
        except OSError:
            pass

    try:
        # Preferred: zero-byte hardlink
        os.link(physical_full_path, full_mirror_path)
        logger.debug(f"Created hardlink mirror: {full_mirror_path} -> {physical_full_path}")
        return full_mirror_path
    except OSError as e:
        logger.warning(f"Hardlink creation failed ({e}), attempting symlink fallback: {full_mirror_path}")
        try:
            # Fallback: relative symlink
            rel_src = os.path.relpath(physical_full_path, os.path.dirname(full_mirror_path))
            os.symlink(rel_src, full_mirror_path)
            return full_mirror_path
        except OSError as sym_err:
            logger.error(f"Mirror link creation failed completely: {sym_err}")
            return None


def store_staged_file(temp_file_path: str, capture_date: Optional[datetime], computed_sha256: str, original_filename: str) -> Tuple[str, str, int]:
    """
    Atomically moves a verified temp upload file into the canonical Vault storage.
    Returns: (canonical_rel_path, canonical_full_path, file_size)
    """
    init_storage_directories()
    canonical_rel_path = get_canonical_relative_path(capture_date, computed_sha256, original_filename)
    canonical_full_path = os.path.join(get_storage_path(), canonical_rel_path)

    os.makedirs(os.path.dirname(canonical_full_path), exist_ok=True)

    # Check if canonical destination already exists (exact duplicate content)
    if os.path.exists(canonical_full_path):
        file_size = os.path.getsize(canonical_full_path)
        try:
            os.remove(temp_file_path)
        except OSError:
            pass
        return canonical_rel_path, canonical_full_path, file_size

    # Atomic move on same filesystem
    shutil.move(temp_file_path, canonical_full_path)
    file_size = os.path.getsize(canonical_full_path)

    return canonical_rel_path, canonical_full_path, file_size
