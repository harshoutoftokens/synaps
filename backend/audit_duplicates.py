#!/usr/bin/env python3
"""
Synaps Duplicate Audit Tool

Scans the existing media library to find exact byte-for-byte duplicates
using SHA-256 content hashing. Generates a report in the root directory.
Does NOT delete or merge any files.
"""
import os
import time
import logging
from collections import defaultdict
from sqlalchemy.orm import Session

from database import SessionLocal
from models import MediaFile
from scanner import compute_content_hash
from config import PROJECT_ROOT

logging.basicConfig(level=logging.INFO, format="%(message)s")
logger = logging.getLogger("synaps.audit")

def format_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes} B"
    elif size_bytes < 1024 ** 2:
        return f"{size_bytes / 1024:.1f} KB"
    elif size_bytes < 1024 ** 3:
        return f"{size_bytes / (1024 ** 2):.1f} MB"
    else:
        return f"{size_bytes / (1024 ** 3):.1f} GB"

def run_audit():
    db = SessionLocal()
    
    logger.info("Starting Duplicate Audit...")
    
    # 1. Group by file_size
    size_groups = defaultdict(list)
    total_files = 0
    
    for media in db.query(MediaFile).filter(MediaFile.file_size > 0).all():
        size_groups[media.file_size].append(media)
        total_files += 1
        
    logger.info(f"Analyzed {total_files} files.")
    
    # Filter groups that have more than 1 file (potential duplicates)
    potential_dupes = {s: items for s, items in size_groups.items() if len(items) > 1}
    logger.info(f"Found {len(potential_dupes)} size collision groups to check hashes for.")
    
    # 2. Check hashes
    exact_duplicates = []
    
    for size, items in potential_dupes.items():
        hash_groups = defaultdict(list)
        
        for item in items:
            if not os.path.exists(item.path):
                continue
                
            chash = item.content_hash
            if not chash:
                # Dynamically compute it
                chash = compute_content_hash(item.path)
                if not chash:
                    continue  # unreadable file: "" must not group unrelated files as duplicates
                item.content_hash = chash
                db.add(item)
                
            hash_groups[chash].append(item)
            
        # Any hash group with >1 file is an exact duplicate
        for chash, dup_items in hash_groups.items():
            if len(dup_items) > 1:
                # Sort by path length or something to pick "original"
                dup_items.sort(key=lambda x: x.path)
                original = dup_items[0]
                for duplicate in dup_items[1:]:
                    exact_duplicates.append({
                        "original": original,
                        "duplicate": duplicate
                    })
                    
    # 3. Generate Report
    report_path = os.path.join(PROJECT_ROOT, "duplicates_report.txt")
    
    with open(report_path, "w") as f:
        f.write("Synaps Duplicate Audit Report\n")
        f.write(f"Generated at: {time.ctime()}\n")
        f.write(f"Total Exact Duplicates Found: {len(exact_duplicates)}\n")
        f.write("-" * 60 + "\n\n")
        
        for dup in exact_duplicates:
            orig = dup["original"]
            copy = dup["duplicate"]
            
            f.write("Original:\n")
            f.write(f"  path: {orig.path}\n")
            f.write(f"  date: {orig.date_taken}\n")
            f.write(f"  size: {format_size(orig.file_size)}\n")
            
            f.write("Duplicate:\n")
            f.write(f"  path: {copy.path}\n")
            f.write(f"  date: {copy.date_taken}\n")
            f.write(f"  size: {format_size(copy.file_size)}\n")
            
            f.write("\n" + ("-" * 40) + "\n\n")
            
    db.commit()
    db.close()
    
    logger.info(f"Audit complete! Found {len(exact_duplicates)} duplicates.")
    logger.info(f"Report saved to: {report_path}")

if __name__ == "__main__":
    run_audit()
