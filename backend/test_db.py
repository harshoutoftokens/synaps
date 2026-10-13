"""Ad-hoc check: print the 10 oldest indexed media rows (python test_db.py)."""
import sys
from database import SessionLocal
from models import MediaFile

if __name__ == "__main__":
    db = SessionLocal()
    try:
        files = db.query(MediaFile).order_by(MediaFile.date_taken).limit(10).all()
        for f in files:
            print(f.id, f.date_taken, f.directory, f.relative_path, f.path)
    finally:
        db.close()
