"""Media endpoints: Range/HEAD/304 on files and streams, cached HEIC previews, thumbnail
caching + placeholder contract, slash-less routes, stats and timeline filters."""
import io
import os
import shutil
import time
import uuid
from datetime import datetime

import pytest
from PIL import Image

from conftest import make_jpeg_bytes


@pytest.fixture
def sandbox(storage_root):
    path = os.path.join(storage_root, f"t_media_{uuid.uuid4().hex[:8]}")
    os.makedirs(path)
    yield path
    shutil.rmtree(path, ignore_errors=True)


def add_media(db, path, **fields):
    from models import MediaFile
    from config import STORAGE_PATH

    ext = os.path.splitext(path)[1].lower()
    values = dict(
        filename=os.path.basename(path), path=path,
        relative_path=os.path.relpath(path, STORAGE_PATH),
        directory=os.path.relpath(os.path.dirname(path), STORAGE_PATH),
        extension=ext, media_type="video" if ext in (".mp4", ".mov") else "image",
        file_size=os.path.getsize(path) if os.path.exists(path) else 0,
    )
    values.update(fields)
    item = MediaFile(**values)
    db.add(item)
    db.commit()
    return item


def heic_bytes(size=(1200, 900), thumbnail=None) -> bytes:
    pytest.importorskip("pillow_heif")
    buf = io.BytesIO()
    kwargs = {"thumbnails": [thumbnail]} if thumbnail else {}
    try:
        Image.new("RGB", size, (30, 140, 200)).save(buf, format="HEIF", quality=50, **kwargs)
    except Exception as e:  # pillow-heif built without an HEVC encoder
        pytest.skip(f"HEIC encoding unavailable: {e}")
    return buf.getvalue()


def wait_for(fn, timeout=15.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = fn()
        if result:
            return result
        time.sleep(0.05)
    raise AssertionError("condition not met in time")


def test_file_and_stream_support_range_head_and_304(client, sandbox, db_session):
    data = os.urandom(1000)
    path = os.path.join(sandbox, "movie.mp4")
    with open(path, "wb") as f:
        f.write(data)
    item = add_media(db_session, path, mime_type="video/mp4")

    for url in (f"/api/media/file/{item.id}", f"/api/media/stream/{item.id}"):
        full = client.get(url)
        assert full.status_code == 200 and full.content == data
        assert full.headers["accept-ranges"] == "bytes"
        assert full.headers["content-type"] == "video/mp4"
        assert full.headers["etag"] and full.headers["last-modified"]

        part = client.get(url, headers={"Range": "bytes=0-99"})
        assert part.status_code == 206
        assert part.content == data[:100]
        assert part.headers["content-range"] == "bytes 0-99/1000"
        assert part.headers["content-length"] == "100"

        suffix = client.get(url, headers={"Range": "bytes=-100"})
        assert suffix.status_code == 206 and suffix.content == data[-100:]
        assert suffix.headers["content-range"] == "bytes 900-999/1000"

        head = client.head(url)
        assert head.status_code == 200 and head.content == b""
        assert head.headers["content-length"] == "1000"

        assert client.get(url, headers={"If-None-Match": full.headers["etag"]}).status_code == 304
        assert client.get(url, headers={"If-Modified-Since": full.headers["last-modified"]}).status_code == 304
        assert client.get(url, headers={"If-None-Match": '"other"'}).status_code == 200


def test_missing_media_and_files(client, sandbox, db_session):
    assert client.get("/api/media/file/does-not-exist").status_code == 404
    item = add_media(db_session, os.path.join(sandbox, "gone.jpg"))
    assert client.get(f"/api/media/file/{item.id}").status_code == 404
    assert client.get(f"/api/media/stream/{item.id}").status_code == 404
    assert client.get(f"/api/media/thumbnail/{item.id}").status_code == 404


def test_heic_preview_is_converted_once_and_cached(client, sandbox, db_session, monkeypatch):
    import thumbnails

    path = os.path.join(sandbox, "IMG_0001.HEIC")
    with open(path, "wb") as f:
        f.write(heic_bytes(size=(3000, 2000)))
    item = add_media(db_session, path, mime_type="image/heic")

    opened = []
    real_open = thumbnails.Image.open
    monkeypatch.setattr(thumbnails.Image, "open", lambda *a, **k: opened.append(a[0]) or real_open(*a, **k))

    first = client.get(f"/api/media/file/{item.id}")
    assert first.status_code == 200
    assert first.headers["content-type"] == "image/jpeg"
    with Image.open(io.BytesIO(first.content)) as img:
        assert img.format == "JPEG" and max(img.size) == 2560
    assert 'filename="IMG_0001.jpg"' in first.headers["content-disposition"]

    second = client.get(f"/api/media/file/{item.id}")
    assert second.status_code == 200 and second.content == first.content
    assert opened.count(path) == 1  # served from the on-disk cache the second time

    assert client.get(f"/api/media/file/{item.id}", headers={"If-None-Match": first.headers["etag"]}).status_code == 304
    part = client.get(f"/api/media/file/{item.id}", headers={"Range": "bytes=0-9"})
    assert part.status_code == 206 and part.content == first.content[:10]

    # The original bytes stay available
    original = client.get(f"/api/media/file/{item.id}", params={"original": 1})
    assert original.status_code == 200
    with open(path, "rb") as f:
        assert original.content == f.read()
    assert "attachment" in original.headers["content-disposition"]

    # A changed source gets a new preview
    with open(path, "wb") as f:
        f.write(heic_bytes(size=(800, 600)))
    third = client.get(f"/api/media/file/{item.id}")
    with Image.open(io.BytesIO(third.content)) as img:
        assert img.size == (800, 600)


def test_heic_preview_busy_returns_503(client, sandbox, db_session, monkeypatch):
    import thumbnails

    path = os.path.join(sandbox, "busy.heic")
    with open(path, "wb") as f:
        f.write(heic_bytes())
    item = add_media(db_session, path)
    monkeypatch.setattr(thumbnails, "PREVIEW_WAIT_SECONDS", 0.05)
    assert thumbnails._preview_semaphore.acquire(timeout=5)
    try:
        r = client.get(f"/api/media/file/{item.id}")
    finally:
        thumbnails._preview_semaphore.release()
    assert r.status_code == 503
    assert r.headers["retry-after"] == "5"


def test_thumbnail_placeholder_then_cached_webp(client, sandbox, db_session):
    path = os.path.join(sandbox, "photo.jpg")
    with open(path, "wb") as f:
        f.write(make_jpeg_bytes(size=(800, 600)))
    item = add_media(db_session, path)
    url = f"/api/media/thumbnail/{item.id}"

    first = client.get(url)
    if first.headers["content-type"].startswith("image/svg"):
        # The web grid polls with HEAD while the content-type is SVG
        assert first.status_code == 200
        assert first.headers["cache-control"] == "no-store"
        assert client.head(url).status_code == 200

    ready = wait_for(lambda: (lambda r: r if r.headers["content-type"] == "image/webp" else None)(client.get(url)))
    assert ready.status_code == 200
    assert "max-age" in ready.headers["cache-control"]
    with Image.open(io.BytesIO(ready.content)) as img:
        assert img.format == "WEBP" and max(img.size) <= 320

    etag = ready.headers["etag"]
    assert client.get(url, headers={"If-None-Match": etag}).status_code == 304
    assert client.get(url, headers={"If-None-Match": f'W/{etag}'}).status_code == 304
    assert client.head(url).headers["content-type"] == "image/webp"

    # The worker marks the row
    db_session.expire_all()
    wait_for(lambda: db_session.get(type(item), item.id).has_thumbnail or db_session.expire_all())


def test_thumbnail_regenerated_when_source_changes(client, sandbox, db_session):
    from thumbnails import get_thumbnail_path

    path = os.path.join(sandbox, "edited.jpg")
    with open(path, "wb") as f:
        f.write(make_jpeg_bytes(size=(400, 300), color=(255, 0, 0)))
    item = add_media(db_session, path)
    url = f"/api/media/thumbnail/{item.id}"
    wait_for(lambda: client.get(url).headers["content-type"] == "image/webp")
    old_etag = client.get(url).headers["etag"]

    with open(path, "wb") as f:
        f.write(make_jpeg_bytes(size=(400, 300), color=(0, 0, 255)))
    future = time.time() + 5
    os.utime(path, (future, future))  # newer than the cached thumbnail
    assert client.get(url).headers["content-type"].startswith("image/svg")
    new = wait_for(lambda: (lambda r: r if r.headers["content-type"] == "image/webp" else None)(client.get(url)))
    assert new.headers["etag"] != old_etag
    with Image.open(get_thumbnail_path(path)) as img:
        r, g, b = img.convert("RGB").getpixel((10, 10))
        assert b > 200 and r < 60


def test_failed_thumbnail_answers_404(client, sandbox, db_session):
    path = os.path.join(sandbox, "corrupt.jpg")
    with open(path, "wb") as f:
        f.write(b"definitely not a jpeg")
    item = add_media(db_session, path)
    url = f"/api/media/thumbnail/{item.id}"
    client.get(url)
    wait_for(lambda: client.get(url).status_code == 404)


def test_stats_match_counts(client, sandbox, db_session, clean_db):
    for i, (media_type, shot, fav, size) in enumerate([
        ("image", True, False, 100), ("image", False, True, 200), ("video", False, True, 300), ("document", False, False, 0),
    ]):
        add_media(db_session, os.path.join(sandbox, f"f{i}.jpg"), media_type=media_type,
                  is_screenshot=shot, is_favorite=fav, file_size=size)
    stats = client.get("/api/media/stats").json()
    assert stats == {
        "total_files": 4, "images": 2, "videos": 1, "documents": 1, "screenshots": 1, "favorites": 2,
        "total_size_bytes": 600, "total_size_human": "600.0 B",
    }


def test_stats_on_empty_library(client, clean_db):
    stats = client.get("/api/media/stats").json()
    assert stats["total_files"] == 0 and stats["total_size_human"] == "0 B"


def test_timeline_year_and_month_filters(client, sandbox, db_session, clean_db):
    dates = {
        "a": datetime(2024, 12, 31, 23, 59), "b": datetime(2025, 1, 1, 0, 0),
        "c": datetime(2025, 12, 15), "d": datetime(2026, 1, 1),
    }
    for name, dt in dates.items():
        add_media(db_session, os.path.join(sandbox, f"{name}.jpg"), date_taken=dt)

    def ids(**params):
        body = client.get("/api/media", params={"view": "gallery", "per_page": 200, **params}).json()
        return sorted(i["filename"] for i in body["items"]), body["total"]

    assert ids(year=2025) == (["b.jpg", "c.jpg"], 2)
    assert ids(year=2025, month=12) == (["c.jpg"], 1)
    assert ids(year=2024, month=12) == (["a.jpg"], 1)
    assert ids(month=1) == (["b.jpg", "d.jpg"], 2)
    assert ids(year=2025, month=13) == ([], 0)

    timeline = client.get("/api/media", params={"per_page": 2}).json()
    assert timeline["total"] == 4 and timeline["total_pages"] == 2
    assert [g["year"] for g in timeline["groups"]] == [2026, 2025]


def test_media_root_routes_without_redirect(client):
    for url in ("/api/media", "/api/media/"):
        r = client.get(url, follow_redirects=False)
        assert r.status_code == 200, url
