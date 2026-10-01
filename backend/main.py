"""
Synaps — Personal NAS Media OS
Main FastAPI application entry point.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager
import os
import threading
import logging

from database import init_db, SessionLocal
from scanner import scan_directory
from config import HOST, PORT, THUMBNAIL_DIR, TRASH_DIR, IMPORT_SOURCE_DIR

# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("synaps")


def run_initial_scan():
    """Run initial scan in a background thread."""
    db = SessionLocal()
    try:
        logger.info("Starting initial media scan...")
        stats = scan_directory(db)
        logger.info(f"Scan complete: {stats}")
    except Exception as e:
        logger.error(f"Scan error: {e}", exc_info=True)
    finally:
        db.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: init DB and run scan on startup."""
    init_db()
    os.makedirs(THUMBNAIL_DIR, exist_ok=True)
    os.makedirs(TRASH_DIR, exist_ok=True)
    os.makedirs(IMPORT_SOURCE_DIR, exist_ok=True)

    # Run scan in background thread to not block startup
    scan_thread = threading.Thread(target=run_initial_scan, daemon=True)
    scan_thread.start()

    yield


app = FastAPI(
    title="Synaps",
    description="Personal NAS Media OS",
    version="1.0.0",
    lifespan=lifespan,
)

# CORS - allow frontend
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Register routers
from routers.media import router as media_router
from routers.finder import router as finder_router
from routers.sync import router as sync_router
from routers.search import router as search_router
from routers.trash import router as trash_router
from routers.settings import router as settings_router
from routers.imports import router as imports_router

app.include_router(media_router)
app.include_router(finder_router)
app.include_router(sync_router)
app.include_router(search_router)
app.include_router(trash_router)
app.include_router(settings_router)
app.include_router(imports_router)


@app.get("/health")
@app.get("/api/health")
def health():
    return {"status": "ok", "app": "Synaps", "version": "1.0.0"}


@app.post("/api/scan")
def trigger_scan():
    """Manually trigger a rescan."""
    thread = threading.Thread(target=run_initial_scan, daemon=True)
    thread.start()
    return {"status": "scan_started"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host=HOST, port=PORT, reload=False)
