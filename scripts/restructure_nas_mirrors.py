#!/usr/bin/env python3
"""
Synaps NAS Storage & Mirror Architecture Alignment Script
1. Consolidates Vault_v2 (13 test files) into canonical Vault/2026/09/
2. Updates database records in synaps.db
3. Recreates /storage/Mirrors/ matching the exact pre-restructuring Vault hierarchy
4. Moves/merges remaining Git repos and metadata from Vault/{Harsh, windows-pc} into Mirrors
5. Removes obsolete flat mirror directories and empty legacy Vault shells
"""
import os
import sys
import shutil
import sqlite3
import logging

STORAGE_ROOT = "/storage"
VAULT_DIR = os.path.join(STORAGE_ROOT, "Vault")
VAULT_V2_DIR = os.path.join(STORAGE_ROOT, "Vault_v2")
MIRRORS_DIR = os.path.join(STORAGE_ROOT, "Mirrors")
DB_PATH = "/home/darkknight48981/nas_dashboard/backend/synaps.db"

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("restructure")

def step1_consolidate_vault_v2(conn):
    logger.info("=== STEP 1: Consolidating Vault_v2 into Vault ===")
    v2_source = os.path.join(VAULT_V2_DIR, "2026", "09")
    v1_target = os.path.join(VAULT_DIR, "2026", "09")
    os.makedirs(v1_target, exist_ok=True)

    moved_count = 0
    if os.path.exists(v2_source):
        for fname in os.listdir(v2_source):
            src_f = os.path.join(v2_source, fname)
            dst_f = os.path.join(v1_target, fname)
            if os.path.isfile(src_f):
                shutil.move(src_f, dst_f)
                moved_count += 1
                logger.info(f"Moved to canonical Vault: {fname}")

    # Remove Vault_v2 if empty
    if os.path.exists(VAULT_V2_DIR):
        shutil.rmtree(VAULT_V2_DIR)
        logger.info("Removed /storage/Vault_v2 directory.")

    # Update database
    cur = conn.cursor()
    cur.execute("""
        UPDATE physical_objects
        SET physical_path = REPLACE(physical_path, 'Vault_v2/', 'Vault/')
        WHERE physical_path LIKE 'Vault_v2/%';
    """)
    db_updated = cur.rowcount
    conn.commit()
    logger.info(f"Step 1 Complete: {moved_count} files moved, {db_updated} database records updated.")


def step2_recreate_mirrors_hierarchy(conn):
    logger.info("=== STEP 2: Building Restructured Mirrors Hierarchy ===")
    cur = conn.cursor()

    # Query all physical objects and their logical items
    rows = cur.execute("""
        SELECT p.physical_path, l.source_id, l.original_path, l.original_filename
        FROM physical_objects p
        JOIN logical_items l ON p.id = l.physical_object_id;
    """).fetchall()

    logger.info(f"Loaded {len(rows)} logical items to mirror.")

    hardlinks_created = 0
    skipped_existing = 0

    for phys_rel, source_id, orig_path, orig_fname in rows:
        phys_full = os.path.join(STORAGE_ROOT, phys_rel)
        if not os.path.exists(phys_full):
            continue

        # Determine target mirror relative path
        norm_orig = orig_path.replace("\\", "/").strip("/")

        if norm_orig.startswith("Vault/"):
            # Original pre-restructuring path e.g. Vault/Harsh/Mac/Documents/...
            mirror_rel = norm_orig[len("Vault/"):]
        elif "/Downloads/" in norm_orig or norm_orig.startswith("Downloads/"):
            # Test files uploaded from Mac client e.g. /Users/harshrathod/Downloads/file.zip
            sub = norm_orig.split("/Downloads/")[-1] if "/Downloads/" in norm_orig else norm_orig
            mirror_rel = os.path.join("Harsh", "Mac", "Downloads", sub)
        elif "/Documents/" in norm_orig:
            sub = norm_orig.split("/Documents/")[-1]
            mirror_rel = os.path.join("Harsh", "Mac", "Documents", sub)
        elif "/Desktop/" in norm_orig:
            sub = norm_orig.split("/Desktop/")[-1]
            mirror_rel = os.path.join("Harsh", "Mac", "Desktop", sub)
        elif "/Pictures/" in norm_orig:
            sub = norm_orig.split("/Pictures/")[-1]
            mirror_rel = os.path.join("Harsh", "Mac", "Pictures", sub)
        elif source_id == "mac_harsh":
            mirror_rel = os.path.join("Harsh", "Mac", norm_orig.split("/")[-1])
        elif source_id == "iphone_harsh":
            mirror_rel = os.path.join("Harsh", "Iphone", norm_orig.split("/")[-1])
        elif source_id == "gdrive_harsh":
            mirror_rel = os.path.join("Harsh", "GoogleDrive", norm_orig.split("/")[-1])
        elif source_id == "win_laptop_hp":
            mirror_rel = os.path.join("Windows_laptop-HP", norm_orig.split("/")[-1])
        elif source_id == "win_pc":
            mirror_rel = os.path.join("windows-pc", norm_orig.split("/")[-1])
        else:
            mirror_rel = norm_orig

        mirror_full = os.path.join(MIRRORS_DIR, mirror_rel)
        os.makedirs(os.path.dirname(mirror_full), exist_ok=True)

        if os.path.lexists(mirror_full):
            try:
                if os.stat(phys_full).st_ino == os.stat(mirror_full).st_ino:
                    skipped_existing += 1
                    continue
                else:
                    os.remove(mirror_full)
            except OSError:
                pass

        try:
            os.link(phys_full, mirror_full)
            hardlinks_created += 1
        except OSError as e:
            logger.warning(f"Could not hardlink {phys_full} -> {mirror_full}: {e}")

        if (hardlinks_created + skipped_existing) % 10000 == 0:
            logger.info(f"Mirror progress: {hardlinks_created + skipped_existing}/{len(rows)} items processed.")

    logger.info(f"Step 2 Complete: {hardlinks_created} hardlinks created, {skipped_existing} existing preserved.")


def step3_merge_legacy_vault_data():
    logger.info("=== STEP 3: Merging Remaining Git Repos & Metadata into Mirrors ===")
    
    # Directories under Vault to merge into Mirrors
    for legacy_name in ["Harsh", "windows-pc", "Windows_laptop-HP"]:
        legacy_src = os.path.join(VAULT_DIR, legacy_name)
        if not os.path.exists(legacy_src):
            continue

        target_mirror_base = os.path.join(MIRRORS_DIR, legacy_name)

        merged_files = 0
        for root, dirs, files in os.walk(legacy_src, topdown=False):
            rel_dir = os.path.relpath(root, legacy_src)
            target_dir = os.path.join(target_mirror_base, rel_dir) if rel_dir != "." else target_mirror_base

            for f in files:
                src_file = os.path.join(root, f)
                dst_file = os.path.join(target_dir, f)
                os.makedirs(target_dir, exist_ok=True)

                if os.path.exists(dst_file):
                    try:
                        os.remove(src_file)
                    except OSError:
                        pass
                else:
                    try:
                        shutil.move(src_file, dst_file)
                        merged_files += 1
                    except OSError as e:
                        logger.warning(f"Error moving {src_file} -> {dst_file}: {e}")

            # Try to remove empty dir
            try:
                os.rmdir(root)
            except OSError:
                pass

        # Final check if legacy directory is gone
        if os.path.exists(legacy_src):
            try:
                os.rmdir(legacy_src)
            except OSError:
                pass

        logger.info(f"Merged {merged_files} files from Vault/{legacy_name} into Mirrors/{legacy_name}.")


def step4_cleanup_flat_mirrors():
    logger.info("=== STEP 4: Cleaning up Obsolete Flat Mirror Directories ===")
    flat_dirs = [
        "mac_harsh", "Harsh's Mac", "MacBook", "gdrive_harsh",
        "iphone_harsh", "iphone_harsh_imports", "win_laptop_hp", "win_pc"
    ]
    for d in flat_dirs:
        p = os.path.join(MIRRORS_DIR, d)
        if os.path.exists(p):
            try:
                shutil.rmtree(p)
                logger.info(f"Removed obsolete mirror directory: Mirrors/{d}")
            except OSError as e:
                logger.warning(f"Could not remove Mirrors/{d}: {e}")


def main():
    logger.info("Starting Synaps NAS Restructuring and Mirror Alignment...")
    conn = sqlite3.connect(DB_PATH)
    try:
        step1_consolidate_vault_v2(conn)
        step2_recreate_mirrors_hierarchy(conn)
        step3_merge_legacy_vault_data()
        step4_cleanup_flat_mirrors()
        logger.info("All NAS restructuring steps completed successfully!")
    finally:
        conn.close()

if __name__ == "__main__":
    main()
