"""OBSOLETE - do not run on a current database.

Startup (database.init_db) now adds the media_files.source column and fills it itself.
This script predates the Vault/YYYY/MM layout: it ignores SYNAPS_DB_URL and would set the
source of canonical vault files to a month number. Kept only for history.
"""
import sqlite3
import os
import sys

# Add backend directory to sys.path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from config import SOURCE_MAPPING, BASE_DIR

db_path = os.path.join(BASE_DIR, "synaps.db")
if not os.path.exists(db_path):
    print(f"Database not found at {db_path}")
    sys.exit(1)

conn = sqlite3.connect(db_path)
cursor = conn.cursor()

# Check if source column exists
cursor.execute("PRAGMA table_info(media_files)")
columns = [col[1] for col in cursor.fetchall()]

if "source" not in columns:
    print("Adding 'source' column to media_files table...")
    cursor.execute("ALTER TABLE media_files ADD COLUMN source VARCHAR")
    cursor.execute("CREATE INDEX ix_media_files_source ON media_files (source)")
    conn.commit()
else:
    print("'source' column already exists.")

print("Populating 'source' column based on relative_path...")
cursor.execute("SELECT id, relative_path FROM media_files")
rows = cursor.fetchall()

updates = []
for row_id, rel_path in rows:
    # rel_path format: Vault/Harsh/Iphone/2026/05/IMG_1.jpg
    # parts: ['Vault', 'Harsh', 'Iphone', ...]
    parts = rel_path.split('/')
    source = "unknown"
    if len(parts) >= 3 and parts[0] == "Vault":
        # The 3rd part is the device/source folder (e.g. 'Iphone', 'Mac')
        raw_source = parts[2]
        source = SOURCE_MAPPING.get(raw_source, raw_source.lower())
    updates.append((source, row_id))

cursor.executemany("UPDATE media_files SET source = ? WHERE id = ?", updates)
conn.commit()
conn.close()

print(f"Successfully updated {len(updates)} records.")
