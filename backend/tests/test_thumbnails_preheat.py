"""preheat_thumbnails.py: generates missing thumbnails, skips fresh ones, stays inside storage."""
import os
import shutil
import uuid

import pytest
from PIL import Image

import preheat_thumbnails
from thumbnails import get_thumbnail_path


@pytest.fixture
def sandbox(storage_root):
    rel = f"t_preheat_{uuid.uuid4().hex[:8]}"
    path = os.path.join(storage_root, rel)
    os.makedirs(os.path.join(path, "2026", "09"))
    os.makedirs(os.path.join(path, ".hidden"))
    yield rel, path
    shutil.rmtree(path, ignore_errors=True)


def test_preheat_generates_then_skips(sandbox, capsys):
    rel, path = sandbox
    files = []
    for i in range(3):
        p = os.path.join(path, "2026", "09", f"IMG_{i}.jpg")
        Image.new("RGB", (640, 480), (i * 40, 0, 0)).save(p, "JPEG")
        files.append(p)
    hidden = os.path.join(path, ".hidden", "skip.jpg")
    Image.new("RGB", (64, 64)).save(hidden, "JPEG")
    with open(os.path.join(path, "2026", "09", "broken.jpg"), "wb") as f:
        f.write(b"nope")

    preheat_thumbnails.preheat_directory(rel, workers=2)
    out = capsys.readouterr().out
    assert "Newly generated:         3" in out and "Failed:                  1" in out
    assert all(os.path.exists(get_thumbnail_path(p)) for p in files)
    assert not os.path.exists(get_thumbnail_path(hidden))

    preheat_thumbnails.preheat_directory(rel)
    out = capsys.readouterr().out
    assert "Already had thumbnails:  3" in out and "Newly generated:         0" in out


def test_preheat_refuses_paths_outside_storage(capsys):
    preheat_thumbnails.preheat_directory("../../etc")
    assert "must stay inside the storage root" in capsys.readouterr().out
