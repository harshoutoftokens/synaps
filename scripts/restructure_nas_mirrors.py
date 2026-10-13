#!/usr/bin/env python3
"""
Synaps NAS Storage & Mirror Architecture Alignment Script
1. Consolidates Vault_v2 (13 test files) into canonical Vault/YYYY/MM/
2. Updates database records in synaps.db
3. Recreates /storage/Mirrors/ matching the exact pre-restructuring Vault hierarchy
4. Moves/merges remaining Git repos and metadata from Vault/{Harsh, windows-pc} into Mirrors
5. Removes obsolete flat mirror directories and empty legacy Vault shells

Safety (this was a one-shot migration; re-running it must never lose data):
- Dry run by default: prints what would happen. Pass --execute (and confirm) to apply.
- Only files that were actually moved get their database path rewritten.
- Directories are only removed when empty (no rmtree).
- A source file is only deleted when an identical copy (same inode, or same size and
  SHA-256) already exists at the destination; otherwise both are kept.
- Obsolete mirror folders lose only hardlinks/symlinks (the bytes live in the Vault);
  unique files in them are kept and reported.

Usage:
  python3 scripts/restructure_nas_mirrors.py                       # dry run
  python3 scripts/restructure_nas_mirrors.py --execute             # apply (asks for confirmation)
  python3 scripts/restructure_nas_mirrors.py --storage-root /storage --db /path/to/synaps.db
"""
import os
import sys
import shutil
import sqlite3
import hashlib
import logging
import argparse

DEFAULT_STORAGE_ROOT = os.getenv("SYNAPS_STORAGE_PATH", "/storage")
DEFAULT_DB_PATH = os.getenv(
    "SYNAPS_DB_PATH",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "backend", "synaps.db"),
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("restructure")


class Plan:
    """Carries the paths and the dry-run flag; every filesystem change goes through it."""

    def __init__(self, storage_root: str, db_path: str, execute: bool):
        self.storage_root = storage_root
        self.vault_dir = os.path.join(storage_root, "Vault")
        self.vault_v2_dir = os.path.join(storage_root, "Vault_v2")
        self.mirrors_dir = os.path.join(storage_root, "Mirrors")
        self.db_path = db_path
        self.execute = execute
        self.kept = []  # files that were deliberately not deleted

    def do(self, description: str, action, *args) -> bool:
        if not self.execute:
            logger.info(f"[dry-run] {description}")
            return True
        try:
            action(*args)
            return True
        except OSError as e:
            logger.warning(f"{description} failed: {e}")
            return False


def _sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def same_content(a: str, b: str) -> bool:
    try:
        sa, sb = os.stat(a), os.stat(b)
    except OSError:
        return False
    if (sa.st_dev, sa.st_ino) == (sb.st_dev, sb.st_ino):
        return True
    return sa.st_size == sb.st_size and _sha256(a) == _sha256(b)


def free_name(path: str, label: str) -> str:
    base, ext = os.path.splitext(path)
    candidate = f"{base} ({label}){ext}"
    n = 2
    while os.path.lexists(candidate):
        candidate = f"{base} ({label} {n}){ext}"
        n += 1
    return candidate


def remove_empty_dirs(plan: Plan, top: str) -> None:
    """Bottom-up rmdir of empty directories under (and including) top."""
    if not os.path.isdir(top):
        return
    for root, dirs, files in os.walk(top, topdown=False):
        try:
            if not os.listdir(root):
                plan.do(f"rmdir {root}", os.rmdir, root)
        except OSError:
            pass


def step1_consolidate_vault_v2(plan: Plan, conn):
    logger.info("=== STEP 1: Consolidating Vault_v2 into Vault ===")
    moved = []
    if os.path.isdir(plan.vault_v2_dir):
        for root, dirs, files in os.walk(plan.vault_v2_dir):
            rel_dir = os.path.relpath(root, plan.vault_v2_dir)
            for fname in files:
                src_f = os.path.join(root, fname)
                dst_f = os.path.normpath(os.path.join(plan.vault_dir, rel_dir, fname))
                if os.path.lexists(dst_f):
                    if same_content(src_f, dst_f):
                        if plan.do(f"remove duplicate {src_f} (identical to {dst_f})", os.remove, src_f):
                            moved.append((src_f, dst_f))
                    else:
                        plan.kept.append(src_f)
                        logger.warning(f"Keeping {src_f}: a different file already exists at {dst_f}")
                    continue
                if plan.execute:
                    os.makedirs(os.path.dirname(dst_f), exist_ok=True)
                if plan.do(f"move {src_f} -> {dst_f}", shutil.move, src_f, dst_f):
                    moved.append((src_f, dst_f))
        # Remove Vault_v2 only once it is empty
        remove_empty_dirs(plan, plan.vault_v2_dir)

    # Update database rows of the files that actually moved
    cur = conn.cursor()
    db_updated = 0
    for src_f, dst_f in moved:
        old_rel = os.path.relpath(src_f, plan.storage_root)
        new_rel = os.path.relpath(dst_f, plan.storage_root)
        if plan.execute:
            cur.execute("UPDATE physical_objects SET physical_path = ? WHERE physical_path = ?", (new_rel, old_rel))
            db_updated += cur.rowcount
        else:
            logger.info(f"[dry-run] UPDATE physical_objects {old_rel} -> {new_rel}")
    if plan.execute:
        conn.commit()
    logger.info(f"Step 1 Complete: {len(moved)} files moved, {db_updated} database records updated.")


def _mirror_rel_for(norm_orig: str, source_id: str) -> str:
    if norm_orig.startswith("Vault/"):
        # Original pre-restructuring path e.g. Vault/Harsh/Mac/Documents/...
        return norm_orig[len("Vault/"):]
    if "/Downloads/" in norm_orig or norm_orig.startswith("Downloads/"):
        # Test files uploaded from Mac client e.g. /Users/harshrathod/Downloads/file.zip
        sub = norm_orig.split("/Downloads/")[-1] if "/Downloads/" in norm_orig else norm_orig
        return os.path.join("Harsh", "Mac", "Downloads", sub)
    for folder in ("Documents", "Desktop", "Pictures"):
        if f"/{folder}/" in norm_orig:
            return os.path.join("Harsh", "Mac", folder, norm_orig.split(f"/{folder}/")[-1])
    flat = {
        "mac_harsh": ("Harsh", "Mac"), "iphone_harsh": ("Harsh", "Iphone"),
        "gdrive_harsh": ("Harsh", "GoogleDrive"), "win_laptop_hp": ("Windows_laptop-HP",),
        "win_pc": ("windows-pc",),
    }
    if source_id in flat:
        return os.path.join(*flat[source_id], norm_orig.split("/")[-1])
    return norm_orig


def step2_recreate_mirrors_hierarchy(plan: Plan, conn):
    logger.info("=== STEP 2: Building Restructured Mirrors Hierarchy ===")
    rows = conn.cursor().execute("""
        SELECT p.physical_path, l.source_id, l.original_path, l.original_filename
        FROM physical_objects p
        JOIN logical_items l ON p.id = l.physical_object_id;
    """).fetchall()
    logger.info(f"Loaded {len(rows)} logical items to mirror.")

    hardlinks_created = 0
    skipped_existing = 0
    for phys_rel, source_id, orig_path, orig_fname in rows:
        phys_full = os.path.join(plan.storage_root, phys_rel)
        if not os.path.exists(phys_full):
            continue
        norm_orig = orig_path.replace("\\", "/").strip("/")
        mirror_full = os.path.normpath(os.path.join(plan.mirrors_dir, _mirror_rel_for(norm_orig, source_id)))
        if os.path.commonpath([mirror_full, plan.mirrors_dir]) != plan.mirrors_dir:
            logger.warning(f"Skipping {orig_path}: mirror path escapes Mirrors/")
            continue

        if os.path.lexists(mirror_full):
            try:
                phys_st, mirror_st, st = os.stat(phys_full), os.stat(mirror_full), os.lstat(mirror_full)
            except OSError:
                continue
            if (phys_st.st_dev, phys_st.st_ino) == (mirror_st.st_dev, mirror_st.st_ino) and not os.path.islink(mirror_full):
                skipped_existing += 1  # already the hardlink we want
                continue
            # Only replace links (the bytes live elsewhere) or identical copies, never unique data
            if not (os.path.islink(mirror_full) or st.st_nlink > 1 or same_content(phys_full, mirror_full)):
                plan.kept.append(mirror_full)
                logger.warning(f"Keeping {mirror_full}: unique file in the way of the mirror for {phys_rel}")
                continue
            plan.do(f"remove stale mirror {mirror_full}", os.remove, mirror_full)

        if plan.execute:
            os.makedirs(os.path.dirname(mirror_full), exist_ok=True)
        if plan.do(f"hardlink {phys_full} -> {mirror_full}", os.link, phys_full, mirror_full):
            hardlinks_created += 1

        if (hardlinks_created + skipped_existing) % 10000 == 0:
            logger.info(f"Mirror progress: {hardlinks_created + skipped_existing}/{len(rows)} items processed.")

    logger.info(f"Step 2 Complete: {hardlinks_created} hardlinks created, {skipped_existing} existing preserved.")


def step3_merge_legacy_vault_data(plan: Plan):
    logger.info("=== STEP 3: Merging Remaining Git Repos & Metadata into Mirrors ===")

    # Directories under Vault to merge into Mirrors
    for legacy_name in ["Harsh", "windows-pc", "Windows_laptop-HP"]:
        legacy_src = os.path.join(plan.vault_dir, legacy_name)
        if not os.path.isdir(legacy_src):
            continue
        target_mirror_base = os.path.join(plan.mirrors_dir, legacy_name)

        merged_files = 0
        for root, dirs, files in os.walk(legacy_src, topdown=False):
            rel_dir = os.path.relpath(root, legacy_src)
            target_dir = os.path.join(target_mirror_base, rel_dir) if rel_dir != "." else target_mirror_base

            for f in files:
                src_file = os.path.join(root, f)
                dst_file = os.path.join(target_dir, f)
                if plan.execute:
                    os.makedirs(target_dir, exist_ok=True)

                if os.path.lexists(dst_file):
                    if same_content(src_file, dst_file):
                        plan.do(f"remove duplicate {src_file}", os.remove, src_file)
                    else:
                        # Different bytes under the same name: keep both
                        alt = free_name(dst_file, "from Vault")
                        if plan.do(f"move {src_file} -> {alt} (name taken by a different file)", shutil.move, src_file, alt):
                            merged_files += 1
                else:
                    if plan.do(f"move {src_file} -> {dst_file}", shutil.move, src_file, dst_file):
                        merged_files += 1

        remove_empty_dirs(plan, legacy_src)
        logger.info(f"Merged {merged_files} files from Vault/{legacy_name} into Mirrors/{legacy_name}.")


def step4_cleanup_flat_mirrors(plan: Plan):
    logger.info("=== STEP 4: Cleaning up Obsolete Flat Mirror Directories ===")
    flat_dirs = [
        "mac_harsh", "Harsh's Mac", "MacBook", "gdrive_harsh",
        "iphone_harsh", "iphone_harsh_imports", "win_laptop_hp", "win_pc"
    ]
    for d in flat_dirs:
        p = os.path.join(plan.mirrors_dir, d)
        if not os.path.isdir(p):
            continue
        for root, dirs, files in os.walk(p):
            for f in files:
                fp = os.path.join(root, f)
                try:
                    st = os.lstat(fp)
                except OSError:
                    continue
                if os.path.islink(fp) or st.st_nlink > 1:
                    plan.do(f"remove link {fp}", os.remove, fp)
                else:
                    plan.kept.append(fp)
                    logger.warning(f"Keeping unique file {fp} (not a hardlink into the Vault)")
        remove_empty_dirs(plan, p)
        logger.info(f"Cleaned obsolete mirror directory: Mirrors/{d}")


def main():
    parser = argparse.ArgumentParser(description="Align NAS storage with the Synaps v2 Vault/Mirrors layout")
    parser.add_argument("--storage-root", default=DEFAULT_STORAGE_ROOT)
    parser.add_argument("--db", default=DEFAULT_DB_PATH, help="Path to synaps.db")
    parser.add_argument("--execute", action="store_true", help="Apply the changes (default: dry run)")
    parser.add_argument("--yes", action="store_true", help="Don't ask for confirmation with --execute")
    args = parser.parse_args()

    storage_root = os.path.realpath(args.storage_root)
    if not os.path.isdir(storage_root) or not os.listdir(storage_root):
        logger.error(f"{storage_root} is missing or empty (disk not mounted?)")
        sys.exit(1)
    if not os.path.isfile(args.db):
        logger.error(f"Database not found: {args.db}")
        sys.exit(1)

    if args.execute and not args.yes:
        print(f"\n  ⚠️  EXECUTE MODE — this moves files under {storage_root} and edits {args.db}.")
        print("  Back up synaps.db first. Run without --execute to preview.\n")
        if input("  Type 'yes' to proceed: ").strip().lower() != "yes":
            print("  Aborted.")
            sys.exit(0)

    plan = Plan(storage_root, args.db, execute=args.execute)
    logger.info(f"Starting Synaps NAS Restructuring and Mirror Alignment ({'EXECUTE' if plan.execute else 'DRY RUN'})...")
    conn = sqlite3.connect(args.db)
    try:
        step1_consolidate_vault_v2(plan, conn)
        step2_recreate_mirrors_hierarchy(plan, conn)
        step3_merge_legacy_vault_data(plan)
        step4_cleanup_flat_mirrors(plan)
        if plan.kept:
            logger.warning(f"{len(plan.kept)} file(s) were kept instead of being deleted/overwritten (see warnings above).")
        logger.info("All NAS restructuring steps completed." if plan.execute else "Dry run complete — nothing was changed.")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
