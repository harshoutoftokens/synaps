"""
Synaps Database Setup - SQLite via SQLAlchemy
"""
from sqlalchemy import create_engine, event
from sqlalchemy.orm import sessionmaker, declarative_base
from config import DATABASE_URL, SQLITE_BUSY_TIMEOUT_MS

IS_SQLITE = DATABASE_URL.startswith("sqlite")

engine = create_engine(
    DATABASE_URL,
    # "timeout" is pysqlite's own busy wait; keep it in step with the PRAGMA below
    connect_args={"check_same_thread": False, "timeout": SQLITE_BUSY_TIMEOUT_MS / 1000} if IS_SQLITE else {},
    echo=False,
)

if IS_SQLITE:
    @event.listens_for(engine, "connect")
    def _configure_sqlite(dbapi_connection, connection_record):
        """
        Per-connection SQLite tuning for a 1-worker server on a slow disk:
        - WAL: readers (timeline, thumbnails) no longer block on an upload's write
          transaction and vice versa. Persistent in the DB file; a no-op once set.
        - busy_timeout: a second writer waits instead of failing with "database is locked".
        - synchronous=NORMAL: in WAL mode this is still corruption-safe; a power cut can only
          lose the last few commits (clients re-check by SHA-256 and re-upload those).
        - cache_size: ~8 MB page cache per connection (the default is ~2 MB).
        Foreign key enforcement stays off (SQLite default): existing NAS databases were
        written without it and may hold rows that would violate it.
        """
        cursor = dbapi_connection.cursor()
        try:
            cursor.execute("PRAGMA journal_mode=WAL")
            cursor.execute(f"PRAGMA busy_timeout={int(SQLITE_BUSY_TIMEOUT_MS)}")
            cursor.execute("PRAGMA synchronous=NORMAL")
            cursor.execute("PRAGMA cache_size=-8000")
        finally:
            cursor.close()

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    """Dependency for FastAPI routes."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


# Indexes added after the tables existed: create_all() never touches an existing table, so
# they are created here, idempotently (no column changes).
EXTRA_INDEXES = [
    # Mirrors/ thumbnail lookups by file name (routers/finder.py)
    "CREATE INDEX IF NOT EXISTS ix_logical_items_original_filename ON logical_items (original_filename)",
    # duplicate checks by size (imports, web uploads)
    "CREATE INDEX IF NOT EXISTS ix_media_files_file_size ON media_files (file_size)",
    # timeline keyset paging: ORDER BY date_taken, id
    "CREATE INDEX IF NOT EXISTS ix_media_files_date_taken_id ON media_files (date_taken, id)",
]


def add_missing_columns(conn) -> list:
    """Add model columns that an older database lacks (SQLite only, nullable columns only).

    create_all() never alters existing tables, so a database created by an older release keeps
    working only if every newer column is added here. Returns "table.column" for each one added.
    """
    added = []
    if not IS_SQLITE:
        return added
    for table in Base.metadata.sorted_tables:
        existing = {row[1] for row in conn.exec_driver_sql(f'PRAGMA table_info("{table.name}")')}
        if not existing:
            continue  # table was just created by create_all()
        for column in table.columns:
            if column.name in existing or column.primary_key or not column.nullable:
                continue
            col_type = column.type.compile(dialect=engine.dialect)
            conn.exec_driver_sql(f'ALTER TABLE "{table.name}" ADD COLUMN "{column.name}" {col_type}')
            if column.index:
                conn.exec_driver_sql(
                    f'CREATE INDEX IF NOT EXISTS "ix_{table.name}_{column.name}" '
                    f'ON "{table.name}" ("{column.name}")'
                )
            added.append(f"{table.name}.{column.name}")
    return added


def _fill_media_sources(conn):
    """Fill media_files.source for rows that predate the column (same rule as the scanner)."""
    from scanner import derive_source

    rows = conn.exec_driver_sql(
        "SELECT id, relative_path FROM media_files WHERE source IS NULL"
    ).fetchall()
    if rows:
        conn.exec_driver_sql(
            "UPDATE media_files SET source = ? WHERE id = ?",
            [(derive_source(rel or ""), row_id) for row_id, rel in rows],
        )


def init_db():
    """Create all tables (v1 and v2), add columns missing from older databases, extra indexes."""
    from models import MediaFile, TrashItem, SyncRecord, Setting  # noqa: F401
    import models_v2  # noqa: F401  (registers the v2 tables on Base.metadata)
    Base.metadata.create_all(bind=engine)
    with engine.begin() as conn:
        added = add_missing_columns(conn)
        if "media_files.source" in added:
            _fill_media_sources(conn)
        for statement in EXTRA_INDEXES:
            conn.exec_driver_sql(statement)
    if added:
        import logging
        logging.getLogger("synaps.database").info("Added missing columns: %s", ", ".join(added))
