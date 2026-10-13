"""
Synaps — Personal NAS Media OS
Main FastAPI application entry point.
"""
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.responses import JSONResponse
from starlette.routing import Match, Mount
from contextlib import asynccontextmanager
from urllib.parse import parse_qsl
import os
import re
import hmac
import time
import threading
import logging

import config
from database import init_db, SessionLocal
from scanner import scan_directory
from config import HOST, PORT, THUMBNAIL_DIR, TRASH_DIR, IMPORT_SOURCE_DIR
from storage_engine import sweep_stale_staging

# Configure structured logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(levelname)s: %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("synaps")


class _RedactTokenFilter(logging.Filter):
    """Keep `?token=...` (contract: query-param auth for <img>/<video> URLs) out of the access log."""
    _token_param = re.compile(r"([?&]token=)[^&\s]*")

    def filter(self, record):
        if isinstance(record.args, tuple) and record.args:
            record.args = tuple(
                self._token_param.sub(r"\1***", arg) if isinstance(arg, str) else arg
                for arg in record.args
            )
        return True


logging.getLogger("uvicorn.access").addFilter(_RedactTokenFilter())

_scan_lock = threading.Lock()

HOUSEKEEPING_INTERVAL_SECONDS = 24 * 3600
TRASH_PURGE_START_DELAY_SECONDS = 10 * 60  # let startup traffic (thumbnail grids) settle first
STAGING_MAX_AGE_SECONDS = 6 * 3600


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


def _run_scan_and_release():
    try:
        run_initial_scan()
    finally:
        _scan_lock.release()


def sweep_staging_area():
    """Delete partial uploads left in STORAGE_PATH/.synaps_tmp by aborted uploads or crashes."""
    try:
        removed = sweep_stale_staging(STAGING_MAX_AGE_SECONDS)
        if removed:
            logger.info(f"Removed {removed} stale partial upload(s) from the staging area")
    except Exception as e:
        logger.warning(f"Staging sweep failed: {e}")


def purge_expired_trash():
    """Apply the 30-day trash retention (the trash router's POST /api/trash/cleanup)."""
    try:
        from routers.trash import cleanup_expired
    except Exception as e:
        logger.warning(f"Trash purge unavailable: {e}")
        return
    db = SessionLocal()
    try:
        result = cleanup_expired(db)  # {"status", "deleted", "errors"}
        logger.info(f"Scheduled trash purge: {result}")
    except Exception as e:
        logger.warning(f"Trash purge failed: {e}")
    finally:
        db.close()


def _housekeeping_loop():
    """Background daemon: staging sweep right away, trash purge after a delay, both daily."""
    sweep_staging_area()
    time.sleep(TRASH_PURGE_START_DELAY_SECONDS)
    while True:
        purge_expired_trash()
        time.sleep(HOUSEKEEPING_INTERVAL_SECONDS)
        sweep_staging_area()


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan: init DB and start background housekeeping."""
    init_db()
    os.makedirs(THUMBNAIL_DIR, exist_ok=True)
    os.makedirs(TRASH_DIR, exist_ok=True)
    os.makedirs(IMPORT_SOURCE_DIR, exist_ok=True)

    threading.Thread(target=_housekeeping_loop, name="synaps-housekeeping", daemon=True).start()
    if config.API_TOKEN:
        logger.info("API token auth is enabled for /api/*")

    # Note: Automated startup scan disabled in v2 to prevent legacy GC on canonical vault
    # Background scans can be triggered via POST /api/scan if needed
    yield


app = FastAPI(
    title="Synaps",
    description="Personal NAS Media OS",
    version="1.0.0",
    lifespan=lifespan,
)


class APITokenMiddleware:
    """
    Opt-in shared-secret auth. When config.API_TOKEN is non-empty, every request to /api/*
    except GET/HEAD /api/health and CORS preflights (OPTIONS) must carry the token as
    `Authorization: Bearer <token>`, cookie `synaps_token=<token>` or query `token=<token>`;
    otherwise 401 {"detail": "unauthorized"}. Non-/api paths (/health, the web app) stay open.
    The token is read per request, so it can be changed without rebuilding the app.
    """

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        token = config.API_TOKEN
        if scope["type"] != "http" or not token or self._is_exempt(scope) or self._has_token(scope, token):
            await self.app(scope, receive, send)
            return
        response = JSONResponse(
            {"detail": "unauthorized"}, status_code=401, headers={"WWW-Authenticate": "Bearer"}
        )
        await response(scope, receive, send)

    @staticmethod
    def _is_exempt(scope) -> bool:
        path = scope.get("path", "")
        if not path.startswith("/api/"):
            return True
        method = scope.get("method", "")
        if method == "OPTIONS":
            return True
        return method in ("GET", "HEAD") and path.rstrip("/") == "/api/health"

    @staticmethod
    def _has_token(scope, token: str) -> bool:
        expected = token.encode("utf-8")
        for name, value in scope.get("headers", []):
            if name == b"authorization":
                scheme, _, credentials = value.partition(b" ")
                if scheme.lower() == b"bearer" and hmac.compare_digest(credentials.strip(), expected):
                    return True
            elif name == b"cookie":
                for pair in value.split(b";"):
                    key, sep, val = pair.strip().partition(b"=")
                    if sep and key.strip() == b"synaps_token":
                        val = val.strip()
                        if len(val) >= 2 and val[:1] == val[-1:] == b'"':
                            val = val[1:-1]
                        if hmac.compare_digest(val, expected):
                            return True
        query = scope.get("query_string", b"")
        if query:
            for key, val in parse_qsl(query.decode("latin-1"), keep_blank_values=True):
                if key == "token" and hmac.compare_digest(val.encode("utf-8"), expected):
                    return True
        return False


app.add_middleware(APITokenMiddleware)

# CORS - added after (so it wraps) the token check: preflights are answered here and 401s
# still carry CORS headers. The web app is same-origin, except direct uploads from :3000 to
# :8000; native apps ignore CORS. Credentialed cross-origin access is limited to LAN origins
# (config.CORS_ORIGIN_REGEX) plus SYNAPS_CORS_ORIGINS; "*" there disables credentials.
if "*" in config.CORS_ORIGINS:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )
else:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=config.CORS_ORIGINS,
        allow_origin_regex=config.CORS_ORIGIN_REGEX or None,
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
from routers.ingest_v2 import router as ingest_v2_router

app.include_router(media_router)
app.include_router(finder_router)
app.include_router(sync_router)
app.include_router(search_router)
app.include_router(trash_router)
app.include_router(settings_router)
app.include_router(imports_router)
app.include_router(ingest_v2_router)


@app.get("/api/health")
@app.get("/health")
def health():
    return {"status": "ok", "app": "Synaps", "version": "1.0.0"}


# HEAD for uptime monitors (kept out of the OpenAPI schema: same operation as GET)
app.add_api_route("/api/health", health, methods=["HEAD"], include_in_schema=False)
app.add_api_route("/health", health, methods=["HEAD"], include_in_schema=False)


@app.post("/api/scan")
def trigger_scan():
    """Manually trigger a rescan (one at a time)."""
    if not _scan_lock.acquire(blocking=False):
        return {"status": "scan_already_running"}
    thread = threading.Thread(target=_run_scan_and_release, daemon=True)
    thread.start()
    return {"status": "scan_started"}


class FrontendStaticFiles(StaticFiles):
    """
    Serves a Next.js static export: "/x" also resolves to "x.html" (exports without
    trailingSlash), and /api/* is never answered with a page, so unknown API paths keep
    their JSON 404.
    """

    async def get_response(self, path, scope):
        if path == "api" or path.startswith("api/"):
            raise StarletteHTTPException(status_code=404)
        response = None
        try:
            response = await super().get_response(path, scope)
            if response.status_code != 404:
                return response
        except StarletteHTTPException as exc:
            if exc.status_code != 404:
                raise
        if path not in ("", ".") and not path.endswith(".html"):
            try:
                alt = await super().get_response(path.rstrip("/") + ".html", scope)
                if alt.status_code != 404:
                    return alt
            except StarletteHTTPException:
                pass
        if response is not None:
            return response
        raise StarletteHTTPException(status_code=404)


class FrontendMount(Mount):
    """
    Mount for the web app that never claims /api/*. A mount at "/" fully matches every path,
    and Starlette prefers a full match over a route that matched only the path, so a GET on a
    PUT-only API route would get the web app's 404 instead of 405 (the Mac app probes
    PUT /api/v2/ingest/stream support exactly that way).
    """

    def matches(self, scope):
        path = scope.get("path", "")
        root_path = scope.get("root_path", "")
        if root_path and path.startswith(root_path):
            path = path[len(root_path):]
        if path == "/api" or path.startswith("/api/"):
            return Match.NONE, {}
        return super().matches(scope)


def mount_frontend(application: FastAPI, dist_dir: str) -> bool:
    """Serve the web app's static export at "/" (must run after every API route is added)."""
    if not dist_dir or not os.path.isdir(dist_dir):
        return False
    application.router.routes.append(
        FrontendMount("/", app=FrontendStaticFiles(directory=dist_dir, html=True), name="frontend")
    )
    logger.info(f"Serving web app from {dist_dir}")
    return True


if config.FRONTEND_DIST:
    if not mount_frontend(app, config.FRONTEND_DIST):
        logger.warning(f"SYNAPS_FRONTEND_DIST is not a directory, web app not served: {config.FRONTEND_DIST}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host=HOST, port=PORT, reload=False)
