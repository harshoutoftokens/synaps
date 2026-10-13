"""Search LIKE escaping + settings validation, storage usage and slash-less routes."""
import os
import time
import uuid

import pytest


def add_media(db, filename, directory="Vault/Harsh/Iphone"):
    from models import MediaFile

    item = MediaFile(
        filename=filename, path=f"/nonexistent/{uuid.uuid4().hex}/{filename}",
        relative_path=f"{directory}/{filename}", directory=directory,
        extension=os.path.splitext(filename)[1].lower(), media_type="image",
    )
    db.add(item)
    db.commit()
    return item


def test_search_escapes_like_wildcards(client, db_session, clean_db):
    add_media(db_session, "IMG_1234.JPG")
    add_media(db_session, "IMGX1234.JPG")
    add_media(db_session, "100% done.png")
    add_media(db_session, "1000 done.png")
    add_media(db_session, "back\\slash.png")

    def names(q):
        return sorted(r["filename"] for r in client.get("/api/search", params={"q": q}).json()["results"])

    assert names("IMG_1234") == ["IMG_1234.JPG"]
    assert names("img_1234") == ["IMG_1234.JPG"]          # still case-insensitive
    assert names("100%") == ["100% done.png"]
    assert names("back\\slash") == ["back\\slash.png"]
    assert names("1234") == sorted(["IMG_1234.JPG", "IMGX1234.JPG"])
    assert names("Harsh/Iphone") == sorted(["IMG_1234.JPG", "IMGX1234.JPG", "100% done.png",
                                            "1000 done.png", "back\\slash.png"])

    s = client.get("/api/search/suggestions", params={"q": "_1"}).json()
    assert s["files"] == ["IMG_1234.JPG"]


@pytest.mark.parametrize("url", ["/api/search", "/api/search/"])
def test_search_without_redirect(client, url):
    r = client.get(url, params={"q": "anything"}, follow_redirects=False)
    assert r.status_code == 200
    assert set(r.json()) >= {"query", "total", "page", "per_page", "results"}


def test_search_rejects_huge_queries(client):
    assert client.get("/api/search", params={"q": "x" * 201}).status_code == 422


@pytest.mark.parametrize("url", ["/api/settings", "/api/settings/"])
def test_settings_get_and_put_without_redirect(client, url, clean_db):
    r = client.get(url, follow_redirects=False)
    assert r.status_code == 200
    body = r.json()
    for key in ("storage_path", "thumbnail_dir", "trash_dir", "theme"):
        assert key in body

    r = client.put(url, json={"theme": "dark"}, follow_redirects=False)
    assert r.status_code == 200 and r.json() == {"status": "success"}
    assert client.get(url).json()["theme"] == "dark"


def test_settings_put_validation(client, clean_db):
    from config import STORAGE_PATH

    for payload in ({"storage_path": "/etc"}, {"evil_key": "1"}, {"theme": "dark", "extra": "1"}):
        r = client.put("/api/settings", json=payload)
        assert r.status_code == 400, payload
    for payload in ({"theme": "neon"}, {"theme": 1}, {"theme": None}):
        assert client.put("/api/settings", json=payload).status_code == 400, payload
    assert client.put("/api/settings", json=["theme"]).status_code == 422
    body = client.get("/api/settings").json()
    assert body["storage_path"] == STORAGE_PATH and "evil_key" not in body


def test_stored_path_rows_cannot_override_config(client, db_session, clean_db):
    from models import Setting
    from config import STORAGE_PATH

    db_session.add(Setting(key="storage_path", value="/somewhere/else"))
    db_session.commit()
    assert client.get("/api/settings").json()["storage_path"] == STORAGE_PATH


def test_storage_usage_is_cached_and_reports_disk(client, monkeypatch):
    import routers.settings as settings_router
    from config import THUMBNAIL_DIR

    os.makedirs(THUMBNAIL_DIR, exist_ok=True)
    with open(os.path.join(THUMBNAIL_DIR, f"probe-{uuid.uuid4().hex}.webp"), "wb") as f:
        f.write(b"x" * 5000)
    settings_router._size_cache.clear()

    walks = []
    real_dir_size = settings_router._dir_size
    monkeypatch.setattr(settings_router, "_dir_size", lambda p: walks.append(p) or real_dir_size(p))

    first = client.get("/api/settings/storage-usage").json()
    for key in ("total_indexed_size", "total_indexed_human", "total_files", "images", "videos", "documents",
                "thumbnail_cache_size", "thumbnail_cache_human", "trash_size", "trash_size_human",
                "disk_total", "disk_used", "disk_free"):
        assert key in first
    assert first["disk_total"] > 0 and first["disk_free"] > 0

    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        usage = client.get("/api/settings/storage-usage").json()
        if usage["thumbnail_cache_size"] >= 5000:
            break
        time.sleep(0.05)
    assert usage["thumbnail_cache_human"] != "Calculating…"
    walked = len(walks)
    for _ in range(3):
        client.get("/api/settings/storage-usage")
    assert len(walks) == walked  # served from the cache, no new directory walks
