"""Finder: path confinement, paged browse (+ media_id), downloads with Range/HEAD/304, tree."""
import os
import shutil
import tempfile
import uuid

import pytest

from conftest import make_jpeg_bytes

SECRET = b"top-secret-outside-storage"


@pytest.fixture
def sandbox(storage_root):
    """A unique folder under the storage root, removed afterwards."""
    rel = f"t_finder_{uuid.uuid4().hex[:8]}"
    path = os.path.join(storage_root, rel)
    os.makedirs(path)
    yield rel, path
    shutil.rmtree(path, ignore_errors=True)


@pytest.fixture
def outside_dir():
    """A directory outside the storage root holding a secret file."""
    path = tempfile.mkdtemp(prefix="synaps-outside-")
    with open(os.path.join(path, "secret.jpg"), "wb") as f:
        f.write(SECRET)
    yield path
    shutil.rmtree(path, ignore_errors=True)


def _write(path, data=b"x"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data)
    return path


ENDPOINTS = ["/api/finder/browse", "/api/finder/download", "/api/finder/thumbnail"]


@pytest.mark.parametrize("endpoint", ENDPOINTS)
@pytest.mark.parametrize("raw_query", [
    "path=../etc/passwd",
    "path=..",
    "path=Vault/../../etc/passwd",
    "path=%2e%2e%2f%2e%2e%2fetc%2fpasswd",            # URL-encoded ../../etc/passwd
    "path=Vault%2f..%2f..%2f..%2fetc",
    "path=a%00b",                                       # NUL byte
])
def test_traversal_rejected_with_400(client, endpoint, raw_query):
    r = client.get(f"{endpoint}?{raw_query}")
    assert r.status_code == 400, r.text
    assert SECRET not in r.content


@pytest.mark.parametrize("endpoint", ENDPOINTS)
@pytest.mark.parametrize("raw_query", [
    "path=/etc/passwd",                                 # absolute: re-rooted under storage, never a host path
    "path=%252e%252e%252fetc%252fpasswd",               # double-encoded: a literal (non-existent) name
    "path=..%5c..%5cetc%5cpasswd",                      # backslashes are ordinary characters on Linux
])
def test_absolute_and_encoded_paths_never_leave_storage(client, endpoint, raw_query):
    r = client.get(f"{endpoint}?{raw_query}")
    assert r.status_code in (400, 404), r.text
    assert b"root:" not in r.content


def test_absolute_path_cannot_reach_outside_file(client, outside_dir):
    r = client.get("/api/finder/download", params={"path": os.path.join(outside_dir, "secret.jpg")})
    assert r.status_code == 404
    assert SECRET not in r.content


def test_symlink_escape_is_forbidden(client, sandbox, outside_dir):
    rel, path = sandbox
    os.symlink(outside_dir, os.path.join(path, "escape_dir"))
    os.symlink(os.path.join(outside_dir, "secret.jpg"), os.path.join(path, "escape.jpg"))

    assert client.get("/api/finder/browse", params={"path": f"{rel}/escape_dir"}).status_code == 403
    for endpoint in ("/api/finder/download", "/api/finder/thumbnail"):
        r1 = client.get(endpoint, params={"path": f"{rel}/escape.jpg"})
        r2 = client.get(endpoint, params={"path": f"{rel}/escape_dir/secret.jpg"})
        assert r1.status_code == 403 and r2.status_code == 403
        assert SECRET not in r1.content + r2.content

    # Escaping links are not even listed
    listing = client.get("/api/finder/browse", params={"path": rel}).json()
    names = [e["name"] for e in listing["folders"] + listing["files"]]
    assert "escape_dir" not in names and "escape.jpg" not in names


def test_symlink_inside_storage_is_allowed(client, sandbox):
    rel, path = sandbox
    _write(os.path.join(path, "real", "photo.jpg"), make_jpeg_bytes())
    os.symlink(os.path.join(path, "real"), os.path.join(path, "alias"))

    listing = client.get("/api/finder/browse", params={"path": rel}).json()
    assert {f["name"] for f in listing["folders"]} == {"alias", "real"}
    r = client.get("/api/finder/download", params={"path": f"{rel}/alias/photo.jpg"})
    assert r.status_code == 200
    assert r.content == make_jpeg_bytes()


def test_hidden_entries_are_unreachable(client, storage_root):
    os.makedirs(os.path.join(storage_root, ".synaps_tmp"), exist_ok=True)
    partial = _write(os.path.join(storage_root, ".synaps_tmp", f"{uuid.uuid4().hex}.upload"), b"partial")
    try:
        assert client.get("/api/finder/browse", params={"path": ".synaps_tmp"}).status_code == 404
        rel = os.path.relpath(partial, storage_root)
        assert client.get("/api/finder/download", params={"path": rel}).status_code == 404
        root = client.get("/api/finder/browse").json()
        assert ".synaps_tmp" not in [f["name"] for f in root["folders"]]
    finally:
        os.remove(partial)


def test_root_aliases(client):
    for params in ({}, {"path": ""}, {"path": "/"}):  # iOS refreshes the root with path=/
        r = client.get("/api/finder/browse", params=params)
        assert r.status_code == 200
        assert r.json()["current_path"] == "/"


def test_dotdot_inside_a_name_is_fine(client, sandbox):
    rel, path = sandbox
    _write(os.path.join(path, "my..file.jpg"), b"data")
    r = client.get("/api/finder/download", params={"path": f"{rel}/my..file.jpg"})
    assert r.status_code == 200 and r.content == b"data"


def test_browse_pages_files_and_keeps_shape(client, sandbox, db_session):
    from models import MediaFile

    rel, path = sandbox
    for i in range(25):
        _write(os.path.join(path, f"img_{i:02d}.jpg"), b"x" * (i + 1))
    os.makedirs(os.path.join(path, "sub"))
    _write(os.path.join(path, "sub", "a.jpg"))
    _write(os.path.join(path, "sub", ".hidden"))
    _write(os.path.join(path, ".dotfile"))

    indexed = os.path.join(path, "img_21.jpg")
    db_session.add(MediaFile(
        filename="img_21.jpg", path=indexed, relative_path=f"{rel}/img_21.jpg",
        directory=rel, extension=".jpg", media_type="image",
    ))
    db_session.commit()

    r = client.get("/api/finder/browse", params={"path": rel, "page": 3, "per_page": 10})
    assert r.status_code == 200
    body = r.json()
    for key in ("current_path", "breadcrumb", "folders", "files", "total_folders", "total_files", "page", "per_page"):
        assert key in body
    assert body["current_path"] == rel
    assert body["total_files"] == 25
    assert body["page"] == 3 and body["per_page"] == 10
    assert [f["name"] for f in body["files"]] == [f"img_{i:02d}.jpg" for i in range(20, 25)]
    assert body["folders"] == [{
        "name": "sub", "path": f"{rel}/sub", "type": "folder", "children_count": 1,
        "modified": body["folders"][0]["modified"],
    }]
    entry = body["files"][1]
    assert entry["path"] == f"{rel}/img_21.jpg"
    assert entry["size"] == 22 and entry["file_type"] == "image" and entry["extension"] == ".jpg"
    for key in ("name", "type", "mime_type", "size_human", "modified"):
        assert key in entry
    media_ids = {f["name"]: f["media_id"] for f in body["files"]}
    assert media_ids["img_21.jpg"] is not None
    assert media_ids["img_20.jpg"] is None
    assert body["breadcrumb"] == [{"name": "Storage", "path": ""}, {"name": rel, "path": rel}]

    # Listing cache is invalidated when the folder changes
    _write(os.path.join(path, "img_99.jpg"))
    assert client.get("/api/finder/browse", params={"path": rel}).json()["total_files"] == 26


def test_browse_errors(client, sandbox):
    rel, path = sandbox
    _write(os.path.join(path, "file.jpg"))
    assert client.get("/api/finder/browse", params={"path": f"{rel}/missing"}).status_code == 404
    assert client.get("/api/finder/browse", params={"path": f"{rel}/file.jpg"}).status_code == 400


def test_display_handles_undecodable_names():
    from routers.finder import _display

    assert _display("plain.jpg") == "plain.jpg"
    undecodable = os.fsdecode(b"caf\xe9.jpg")  # latin-1 byte from an old FAT/Windows copy
    assert _display(undecodable) == "caf�.jpg"


def test_download_supports_range_head_and_304(client, sandbox):
    rel, path = sandbox
    data = bytes(range(256)) * 4  # 1024 bytes
    _write(os.path.join(path, "clip.mp4"), data)
    params = {"path": f"{rel}/clip.mp4"}

    full = client.get("/api/finder/download", params=params)
    assert full.status_code == 200 and full.content == data
    assert full.headers["accept-ranges"] == "bytes"
    assert "attachment" in full.headers["content-disposition"]
    etag = full.headers["etag"]

    part = client.get("/api/finder/download", params=params, headers={"Range": "bytes=0-99"})
    assert part.status_code == 206
    assert part.content == data[:100]
    assert part.headers["content-range"] == "bytes 0-99/1024"

    resume = client.get("/api/finder/download", params=params, headers={"Range": "bytes=1000-"})
    assert resume.status_code == 206 and resume.content == data[1000:]

    suffix = client.get("/api/finder/download", params=params, headers={"Range": "bytes=-100"})
    assert suffix.status_code == 206 and suffix.content == data[-100:]
    assert suffix.headers["content-range"] == "bytes 924-1023/1024"

    head = client.head("/api/finder/download", params=params)
    assert head.status_code == 200
    assert head.headers["content-length"] == "1024"
    assert head.content == b""

    cached = client.get("/api/finder/download", params=params, headers={"If-None-Match": etag})
    assert cached.status_code == 304 and cached.content == b""


def test_download_rejects_directories_and_missing(client, sandbox):
    rel, _ = sandbox
    assert client.get("/api/finder/download", params={"path": rel}).status_code == 400
    assert client.get("/api/finder/download", params={"path": f"{rel}/nope.jpg"}).status_code == 404


def test_tree_depth_hidden_and_symlinks(client, sandbox, outside_dir):
    import routers.finder as finder

    rel, path = sandbox
    os.makedirs(os.path.join(path, "a", "b", "c", "d"))
    os.makedirs(os.path.join(path, ".hidden_dir"))
    os.symlink(outside_dir, os.path.join(path, "outside_link"))
    _write(os.path.join(path, "a", "file.jpg"))
    finder._tree_cache.clear()

    tree = client.get("/api/finder/tree", params={"depth": 3}).json()["tree"]
    node = next(n for n in tree if n["name"] == rel)
    assert [c["name"] for c in node["children"]] == ["a"]           # hidden + escaping link skipped
    a = node["children"][0]
    assert a["path"] == f"{rel}/a"
    assert [c["name"] for c in a["children"]] == ["b"]
    assert a["children"][0]["children"] == []                        # depth limit reached
    assert client.get("/api/finder/tree", params={"depth": 9}).status_code == 422
