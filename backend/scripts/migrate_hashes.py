#!/usr/bin/env python3
"""
Synaps Database Migration: Add Content Hash
"""
import sqlite3
import os
import sys
import logging
# Make the backend modules (config, database, ...) importable however this script is started
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from config import DATABASE_URL

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("synaps.migration")

def migrate():
    # Same database the server uses (honours SYNAPS_DB_URL), not always backend/synaps.db
    if not DATABASE_URL.startswith("sqlite:///"):
        logger.error(f"Only SQLite databases are supported, got {DATABASE_URL}")
        return
    db_path = DATABASE_URL[len("sqlite:///"):]
    if not os.path.exists(db_path):
        logger.error(f"Database not found at {db_path}")
        return

    logger.info(f"Connecting to database at {db_path}...")
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    # Get existing columns in media_files
    cursor.execute("PRAGMA table_info(media_files)")
    media_cols = [row[1] for row in cursor.fetchall()]

    if "content_hash" not in media_cols:
        logger.info("Adding content_hash and hash_algorithm to media_files...")
        cursor.execute("ALTER TABLE media_files ADD COLUMN content_hash VARCHAR(64) DEFAULT NULL")
        cursor.execute("ALTER TABLE media_files ADD COLUMN hash_algorithm VARCHAR(16) DEFAULT 'sha256'")
        cursor.execute("CREATE INDEX ix_media_files_content_hash ON media_files (content_hash)")
    else:
        logger.info("media_files already has content_hash columns.")

    # Get existing columns in sync_records
    cursor.execute("PRAGMA table_info(sync_records)")
    sync_cols = [row[1] for row in cursor.fetchall()]

    if "content_hash" not in sync_cols:
        logger.info("Adding content_hash and hash_algorithm to sync_records...")
        cursor.execute("ALTER TABLE sync_records ADD COLUMN content_hash VARCHAR(64) DEFAULT NULL")
        cursor.execute("ALTER TABLE sync_records ADD COLUMN hash_algorithm VARCHAR(16) DEFAULT 'sha256'")
        cursor.execute("CREATE INDEX ix_sync_records_content_hash ON sync_records (content_hash)")
    else:
        logger.info("sync_records already has content_hash columns.")

    conn.commit()
    conn.close()
    logger.info("Migration completed successfully!")

if __name__ == "__main__":
    migrate()
