"""Thumbnail generation, queue and worker behaviour (thumbnails.py)."""
import io
import os
import shutil
import subprocess
import tempfile
import time

import pytest
from PIL import Image

import thumbnails


@pytest.fixture
def workdir():
    path = tempfile.mkdtemp(prefix="synaps-thumbs-")
    yield path
    shutil.rmtree(path, ignore_errors=True)


def _save(path, img, fmt, **kwargs):
    img.save(path, fmt, **kwargs)
    return path


def test_jpeg_exif_orientation_is_applied(workdir):
    img = Image.new("RGB", (4032, 3024), (10, 200, 10))
    exif = Image.Exif()
    exif[0x0112] = 6  # stored sideways, display rotated 90°
    src = _save(os.path.join(workdir, "portrait.jpg"), img, "JPEG", exif=exif.tobytes())
    out = os.path.join(workdir, "portrait.webp")
    assert thumbnails.generate_image_thumbnail(src, out)
    with Image.open(out) as thumb:
        assert thumb.format == "WEBP"
        assert thumb.size == (240, 320)


def test_jpeg_is_decoded_at_reduced_scale(workdir, monkeypatch):
    src = _save(os.path.join(workdir, "big.jpg"), Image.new("RGB", (4000, 3000), (1, 2, 3)), "JPEG")
    seen = {}
    real_thumbnail = Image.Image.thumbnail

    def spy(self, size, *args, **kwargs):
        seen["size_before_resize"] = self.size
        return real_thumbnail(self, size, *args, **kwargs)

    monkeypatch.setattr(Image.Image, "thumbnail", spy)
    assert thumbnails.generate_image_thumbnail(src, os.path.join(workdir, "big.webp"))
    assert seen["size_before_resize"] == (500, 375)  # DCT-scaled 1/8 instead of 4000x3000


def test_palette_png_and_small_images(workdir):
    pal = Image.new("P", (900, 300))
    pal.putpalette([i % 256 for i in range(768)])
    src = _save(os.path.join(workdir, "pal.png"), pal, "PNG")
    out = os.path.join(workdir, "pal.webp")
    assert thumbnails.generate_image_thumbnail(src, out)
    with Image.open(out) as thumb:
        assert thumb.mode == "RGB" and thumb.size == (320, 107)

    tiny = _save(os.path.join(workdir, "tiny.png"), Image.new("RGBA", (40, 20), (1, 2, 3, 0)), "PNG")
    assert thumbnails.generate_image_thumbnail(tiny, os.path.join(workdir, "tiny.webp"))
    with Image.open(os.path.join(workdir, "tiny.webp")) as thumb:
        assert thumb.size == (40, 20)  # never upscaled


def test_heic_uses_embedded_thumbnail_when_supported(workdir, monkeypatch):
    pillow_heif = pytest.importorskip("pillow_heif")
    src = os.path.join(workdir, "IMG.HEIC")
    try:
        Image.new("RGB", (2400, 1800), (200, 30, 30)).save(src, format="HEIF", quality=40, thumbnails=[320])
    except Exception as e:
        pytest.skip(f"HEIC encoding unavailable: {e}")

    decoded = {}
    real_load = Image.Image.load

    def spy(self):
        decoded.setdefault("size", self.size)
        return real_load(self)

    monkeypatch.setattr(Image.Image, "load", spy)
    out = os.path.join(workdir, "IMG.webp")
    assert thumbnails.generate_image_thumbnail(src, out)
    with Image.open(out) as thumb:
        assert thumb.size == (320, 240)
    with Image.open(src) as probe:
        supports_draft = probe.draft("RGB", (320, 240)) is not None
    # pillow-heif >= 1.8 decodes the 320 px embedded thumbnail instead of the 2400 px image
    assert decoded["size"] == ((320, 240) if supports_draft else (2400, 1800)), pillow_heif.__version__


def test_failed_generation_leaves_no_partial_file(workdir, monkeypatch):
    src = _save(os.path.join(workdir, "ok.jpg"), Image.new("RGB", (100, 100)), "JPEG")
    out = os.path.join(workdir, "ok.webp")

    def broken_save(self, fp, *args, **kwargs):
        with open(fp, "wb") as f:
            f.write(b"RIFF\x00\x00")  # half-written file
        raise OSError("disk full")

    monkeypatch.setattr(Image.Image, "save", broken_save)
    assert not thumbnails.generate_image_thumbnail(src, out)
    assert os.listdir(workdir) == ["ok.jpg"]  # neither the target nor a temp file


def test_freshness_rules(workdir):
    src = os.path.join(workdir, "a.jpg")
    thumb = os.path.join(workdir, "a.webp")
    for p in (src, thumb):
        with open(p, "wb") as f:
            f.write(b"x")
    now = time.time()
    os.utime(src, (now - 100, now - 100))
    os.utime(thumb, (now - 50, now - 50))
    assert thumbnails.find_fresh_thumbnail(thumb, os.stat(src)) is not None
    os.utime(src, (now - 10, now - 10))             # source edited after the thumbnail
    assert thumbnails.find_fresh_thumbnail(thumb, os.stat(src)) is None
    os.utime(src, (now + 86400, now + 86400))       # bad camera clock: don't loop forever
    assert thumbnails.find_fresh_thumbnail(thumb, os.stat(src)) is not None
    open(thumb, "wb").close()                       # truncated/empty thumbnail
    assert thumbnails.find_fresh_thumbnail(thumb, os.stat(src)) is None


def test_queue_is_bounded_lifo_and_deduplicated():
    q = thumbnails._ThumbnailQueue(maxsize=3)
    for name in ("a", "b", "c"):
        assert q.put(name, name + ".webp")
    assert not q.put("b", "b.webp")          # already queued
    assert q.put("d", "d.webp")              # full: oldest ("a") is dropped
    assert q.qsize() == 3
    assert not q.is_pending("a") and q.is_pending("d")
    assert q.get() == ("d", "d.webp")        # newest first
    assert q.is_pending("d")                 # still pending while being generated
    q.done("d")
    assert not q.is_pending("d")
    assert q.put("a", "a.webp")


def test_worker_survives_bad_files_and_remembers_failures(workdir):
    bad = os.path.join(workdir, "bad.jpg")
    with open(bad, "wb") as f:
        f.write(b"not an image")
    good = _save(os.path.join(workdir, "good.jpg"), Image.new("RGB", (64, 64), (5, 5, 5)), "JPEG")

    thumbnails.enqueue_thumbnail(bad)
    thumbnails.enqueue_thumbnail(good)

    deadline = time.monotonic() + 15
    while time.monotonic() < deadline and (
        thumbnails.is_thumbnail_pending(bad) or thumbnails.is_thumbnail_pending(good)
    ):
        time.sleep(0.05)
    assert os.path.exists(thumbnails.get_thumbnail_path(good))
    assert not os.path.exists(thumbnails.get_thumbnail_path(bad))
    assert thumbnails.thumbnail_failed(bad)

    # A remembered failure is not retried on every poll...
    thumbnails.enqueue_thumbnail(bad)
    assert not thumbnails.is_thumbnail_pending(bad)
    # ...but is retried once the file changes
    with open(bad, "wb") as f:
        f.write(b"still not an image, but different")
    assert not thumbnails.thumbnail_failed(bad)


def test_enqueue_skips_missing_sources():
    missing = "/definitely/not/here.jpg"
    thumbnails.enqueue_thumbnail(missing)
    assert not thumbnails.is_thumbnail_pending(missing)


def test_link_and_move_thumbnail(workdir, monkeypatch):
    monkeypatch.setattr(thumbnails, "THUMBNAIL_DIR", workdir)
    old_src, new_src = "/storage/Vault/a.jpg", "/storage/Vault/2020/a.jpg"
    with open(thumbnails.get_thumbnail_path(old_src), "wb") as f:
        f.write(b"webp-bytes")
    alias = thumbnails.get_thumbnail_path("/storage/Mirrors/a.jpg")
    assert thumbnails.link_thumbnail(thumbnails.get_thumbnail_path(old_src), alias)
    with open(alias, "rb") as f:
        assert f.read() == b"webp-bytes"
    assert thumbnails.move_thumbnail(old_src, new_src)
    assert os.path.exists(thumbnails.get_thumbnail_path(new_src))
    assert not os.path.exists(thumbnails.get_thumbnail_path(old_src))


def test_thumbnail_key_is_unchanged_and_survives_undecodable_names():
    import hashlib

    path = "/storage/Vault/Harsh/Iphone/IMG_0001.HEIC"
    expected = hashlib.md5(path.encode()).hexdigest() + ".webp"
    assert thumbnails.get_thumbnail_path(path).endswith(expected)  # existing caches stay valid
    assert thumbnails.get_thumbnail_path(os.fsdecode(b"/storage/caf\xe9.jpg")).endswith(".webp")


def test_video_without_ffmpeg_fails_fast(workdir, monkeypatch):
    monkeypatch.setattr(thumbnails.shutil, "which", lambda name: None)
    called = []
    monkeypatch.setattr(thumbnails.subprocess, "run", lambda *a, **k: called.append(a))
    assert not thumbnails.generate_video_thumbnail(os.path.join(workdir, "clip.mov"), os.path.join(workdir, "c.webp"))
    assert called == []


def test_ffmpeg_command_is_cheap_and_bounded(workdir, monkeypatch):
    monkeypatch.setattr(thumbnails, "_which", lambda tool: "/usr/bin/ffmpeg")
    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"], captured["kwargs"] = cmd, kwargs
        buf = io.BytesIO()
        Image.new("RGB", (320, 180), (9, 9, 9)).save(buf, "PPM")
        return subprocess.CompletedProcess(cmd, 0, stdout=buf.getvalue(), stderr=b"")

    monkeypatch.setattr(thumbnails.subprocess, "run", fake_run)
    out = os.path.join(workdir, "clip.webp")
    assert thumbnails.generate_video_thumbnail(os.path.join(workdir, "clip.mov"), out)
    cmd = captured["cmd"]
    assert cmd.index("-ss") < cmd.index("-i")          # input seek, no decode-and-discard
    for flag in ("-an", "-sn", "-noaccurate_seek"):
        assert flag in cmd
    assert cmd[cmd.index("-frames:v") + 1] == "1"
    assert cmd[cmd.index("-threads") + 1] == "1"
    assert "force_original_aspect_ratio=decrease" in cmd[cmd.index("-vf") + 1]
    assert captured["kwargs"]["timeout"] == thumbnails.FFMPEG_TIMEOUT
    with Image.open(out) as thumb:
        assert thumb.format == "WEBP" and thumb.size == (320, 180)


def test_ffmpeg_timeout_is_handled(workdir, monkeypatch):
    monkeypatch.setattr(thumbnails, "_which", lambda tool: "/usr/bin/ffmpeg")

    def slow(cmd, **kwargs):
        raise subprocess.TimeoutExpired(cmd, kwargs.get("timeout"))

    monkeypatch.setattr(thumbnails.subprocess, "run", slow)
    out = os.path.join(workdir, "slow.webp")
    assert not thumbnails.generate_video_thumbnail(os.path.join(workdir, "slow.mp4"), out)
    assert not os.path.exists(out)


@pytest.mark.skipif(shutil.which("ffmpeg") is None, reason="ffmpeg not installed (it is on the NAS)")
def test_real_video_thumbnail(workdir):
    src = os.path.join(workdir, "test.mp4")
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "testsrc=duration=2:size=1280x720:rate=10",
         "-pix_fmt", "yuv420p", src],
        check=True, timeout=60,
    )
    out = os.path.join(workdir, "test.webp")
    assert thumbnails.generate_video_thumbnail(src, out)
    with Image.open(out) as thumb:
        assert thumb.format == "WEBP" and thumb.size == (320, 180)


def test_preview_cache_eviction(workdir, monkeypatch):
    monkeypatch.setattr(thumbnails, "PREVIEW_DIR", workdir)
    monkeypatch.setattr(thumbnails, "PREVIEW_CACHE_MAX_BYTES", 2500)
    now = time.time()
    for i in range(5):
        p = os.path.join(workdir, f"{i}.jpg")
        with open(p, "wb") as f:
            f.write(b"x" * 1000)
        os.utime(p, (now - 100 + i, now - 100 + i))
    thumbnails._evict_previews()
    assert sorted(os.listdir(workdir)) == ["3.jpg", "4.jpg"]  # least recently used went first
