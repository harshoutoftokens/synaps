#!/usr/bin/env python3
"""
Synaps Media Sampler
====================
Builds a realistic development dataset inside mock_storage by copying 
a small sample of files from the real NAS structure.
"""

import os
import shutil
import argparse
import logging
from typing import List, Tuple

# Supported extensions
VALID_EXTENSIONS = {
    # Images
    '.jpg', '.jpeg', '.png', '.heic', '.webp', '.gif',
    # Videos
    '.mp4', '.mov', '.m4v',
    # Other
    '.aae'
}

# Directories to skip
SKIP_DIRS = {
    'thumbnails', 'cache', 'trash', 'venv', '__pycache__', 'node_modules', '.git'
}

def setup_logging():
    logging.basicConfig(
        level=logging.INFO,
        format='%(message)s'
    )
    return logging.getLogger("sampler")

def is_valid_file(filename: str) -> bool:
    if filename.startswith('.'):
        return False
    if filename.lower().endswith('.db'):
        return False
    
    ext = os.path.splitext(filename)[1].lower()
    return ext in VALID_EXTENSIONS

def select_files(files: List[str], limit: int, dirpath: str) -> List[str]:
    """
    Selects a sample of files based on chronological order.
    Returns a mix of oldest, newest, and middle files.
    """
    if len(files) <= limit:
        return files
    
    # Sort files by modification time
    file_mtimes = []
    for f in files:
        full_path = os.path.join(dirpath, f)
        try:
            mtime = os.path.getmtime(full_path)
        except OSError:
            mtime = 0
        file_mtimes.append((f, mtime))
    
    file_mtimes.sort(key=lambda x: x[1])
    sorted_files = [f for f, _ in file_mtimes]
    
    if limit == 1:
        return [sorted_files[0]]
        
    indices = [int(i * (len(sorted_files) - 1) / (limit - 1)) for i in range(limit)]
    return [sorted_files[idx] for idx in indices]

def main():
    parser = argparse.ArgumentParser(description="Copy a sample of media for development")
    parser.add_argument("--source", type=str, default="/storage/Vault/Harsh/Iphone", 
                        help="Source base directory (e.g., real NAS path)")
    parser.add_argument("--dest", type=str, default="mock_storage/Vault/Harsh/Iphone", 
                        help="Destination base directory")
    parser.add_argument("--limit", type=int, default=10, 
                        help="Maximum number of files to copy per folder")
    parser.add_argument("--dry-run", action="store_true", 
                        help="Show what would be copied without making changes")
    
    args = parser.parse_args()
    logger = setup_logging()

    source_base = os.path.normpath(args.source)
    dest_base = os.path.normpath(args.dest)
    limit = args.limit
    dry_run = args.dry_run

    logger.info("=" * 60)
    logger.info("  Synaps Media Sampler")
    logger.info("=" * 60)
    logger.info(f"Source:      {source_base}")
    logger.info(f"Destination: {dest_base}")
    logger.info(f"Limit:       {limit} files per folder")
    if dry_run:
        logger.info("\n  *** DRY RUN MODE - NO FILES WILL BE COPIED ***")
    logger.info("=" * 60)

    if not os.path.exists(source_base):
        logger.error(f"Error: Source directory does not exist: {source_base}")
        return

    stats = {
        'folders_scanned': 0,
        'files_copied': 0,
        'files_skipped': 0,
        'total_size_bytes': 0
    }

    for root, dirs, files in os.walk(source_base):
        # Filter directories
        dirs[:] = [d for d in dirs if not d.startswith('.') and d.lower() not in SKIP_DIRS]
        
        valid_files = [f for f in files if is_valid_file(f)]
        if not valid_files:
            continue
            
        stats['folders_scanned'] += 1
        
        rel_path = os.path.relpath(root, source_base)
        dest_dir = os.path.join(dest_base, rel_path) if rel_path != "." else dest_base
        
        selected_files = select_files(valid_files, limit, root)
        skipped_count = len(valid_files) - len(selected_files)
        stats['files_skipped'] += skipped_count
        
        if selected_files:
            logger.info(f"\nProcessing: {rel_path} (Selecting {len(selected_files)} / {len(valid_files)} files)")
            
            if not dry_run:
                os.makedirs(dest_dir, exist_ok=True)
                
            for f in selected_files:
                src_path = os.path.join(root, f)
                dst_path = os.path.join(dest_dir, f)
                
                try:
                    size = os.path.getsize(src_path)
                    stats['total_size_bytes'] += size
                    stats['files_copied'] += 1
                    
                    if dry_run:
                        logger.info(f"  [DRY RUN] Copy: {f} ({size / (1024*1024):.2f} MB)")
                    else:
                        shutil.copy2(src_path, dst_path)
                        logger.info(f"  Copied: {f}")
                except Exception as e:
                    logger.error(f"  Failed to copy {f}: {e}")

    logger.info("\n" + "=" * 60)
    logger.info("  Summary")
    logger.info("=" * 60)
    logger.info(f"Folders scanned: {stats['folders_scanned']}")
    logger.info(f"Files copied:    {stats['files_copied']}")
    logger.info(f"Files skipped:   {stats['files_skipped']}")
    
    total_mb = stats['total_size_bytes'] / (1024 * 1024)
    logger.info(f"Total size:      {total_mb:.2f} MB")
    
    if dry_run:
        logger.info("\n(This was a dry run. No files were actually copied.)")

if __name__ == "__main__":
    main()
