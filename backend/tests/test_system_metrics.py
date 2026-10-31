"""system_metrics.py readers, sampling and rollup, and the /api/system dashboard endpoints."""
import os
from datetime import date, datetime, timedelta, timezone
from urllib.parse import urlencode

import pytest

from conftest import make_jpeg_bytes, sha256_hex

import system_metrics
from system_metrics import (
    MetricsSampler, SystemMetricsHourly, SystemMetricsMinute,
    prune, read_cpu_temperature, read_cpu_times, read_memory, read_network_bytes, roll_up_hours,
    store_sample,
)


# ── Fake /proc and /sys ───────────────────────────────────────────────────

def write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(content)


NET_DEV = """Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: {lo} 10 0 0 0 0 0 0 {lo} 10 0 0 0 0 0 0
enp2s0: {rx} 100 0 0 0 0 0 0 {tx} 100 0 0 0 0 0 0
docker0: 999999 5 0 0 0 0 0 0 999999 5 0 0 0 0 0 0
"""

MEMINFO = """MemTotal:        2048000 kB
MemFree:          100000 kB
MemAvailable:     512000 kB
Buffers:           20000 kB
Cached:           300000 kB
SwapTotal:       1024000 kB
SwapFree:         768000 kB
"""


def fake_proc(root, busy, idle, rx, tx):
    # cpu  user nice system idle iowait irq softirq steal
    write(os.path.join(root, "stat"), f"cpu  {busy} 0 0 {idle} 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0\n")
    write(os.path.join(root, "meminfo"), MEMINFO)
    write(os.path.join(root, "loadavg"), "0.52 0.40 0.31 1/123 4567\n")
    write(os.path.join(root, "uptime"), "86400.50 160000.00\n")
    write(os.path.join(root, "net", "dev"), NET_DEV.format(lo=5000, rx=rx, tx=tx))


def test_readers_parse_proc_files(tmp_path):
    proc = str(tmp_path / "proc")
    fake_proc(proc, busy=300, idle=700, rx=1000, tx=2000)

    assert read_cpu_times(proc) == (300, 1000)
    memory = read_memory(proc)
    assert memory["total"] == 2048000 * 1024
    assert memory["used"] == (2048000 - 512000) * 1024
    assert memory["swap_used"] == 256000 * 1024
    # loopback and docker traffic is left out
    assert read_network_bytes(proc) == (1000, 2000)
    assert system_metrics.read_loadavg(proc) == (0.52, 0.40, 0.31)
    assert system_metrics.read_uptime(proc) == 86400.5


def test_readers_return_none_without_proc(tmp_path):
    missing = str(tmp_path / "nothing")
    assert read_cpu_times(missing) is None
    assert read_memory(missing) is None
    assert read_network_bytes(missing) is None
    assert system_metrics.read_loadavg(missing) is None
    assert read_cpu_temperature(missing) is None


def test_memory_without_memavailable_uses_free_plus_caches(tmp_path):
    proc = str(tmp_path / "proc")
    write(os.path.join(proc, "meminfo"), "\n".join(
        line for line in MEMINFO.splitlines() if not line.startswith("MemAvailable")))
    assert read_memory(proc)["available"] == (100000 + 20000 + 300000) * 1024


def test_temperature_prefers_coretemp_hottest_core(tmp_path):
    sys_root = str(tmp_path / "sys")
    write(os.path.join(sys_root, "class/hwmon/hwmon0/name"), "acpitz\n")
    write(os.path.join(sys_root, "class/hwmon/hwmon0/temp1_input"), "90000\n")
    write(os.path.join(sys_root, "class/hwmon/hwmon1/name"), "coretemp\n")
    write(os.path.join(sys_root, "class/hwmon/hwmon1/temp2_input"), "48000\n")
    write(os.path.join(sys_root, "class/hwmon/hwmon1/temp3_input"), "51500\n")
    assert read_cpu_temperature(sys_root) == 51.5


def test_temperature_falls_back_to_thermal_zone(tmp_path):
    sys_root = str(tmp_path / "sys")
    write(os.path.join(sys_root, "class/thermal/thermal_zone0/type"), "acpitz\n")
    write(os.path.join(sys_root, "class/thermal/thermal_zone0/temp"), "44000\n")
    write(os.path.join(sys_root, "class/thermal/thermal_zone1/type"), "battery\n")
    write(os.path.join(sys_root, "class/thermal/thermal_zone1/temp"), "99000\n")
    assert read_cpu_temperature(sys_root) == 44.0


def test_sampler_computes_rates_from_consecutive_samples(tmp_path, storage_root):
    proc = str(tmp_path / "proc")
    ticks = iter([100.0, 160.0, 220.0])
    sampler = MetricsSampler(proc_root=proc, sys_root=str(tmp_path / "sys"), storage_path=storage_root,
                             clock=lambda: 1_700_000_000, monotonic=lambda: next(ticks))

    fake_proc(proc, busy=300, idle=700, rx=1000, tx=2000)
    first = sampler.sample()
    assert first["cpu_percent"] is None and first["net_rx_bps"] is None  # needs two readings
    assert first["mem_total"] == 2048000 * 1024
    assert first["disk_total"] > 0

    fake_proc(proc, busy=600, idle=1400, rx=7000, tx=3200)  # +300 busy of +1000 total, 60 s later
    second = sampler.sample()
    assert second["cpu_percent"] == 30.0
    assert second["net_rx_bps"] == 100.0
    assert second["net_tx_bps"] == 20.0

    fake_proc(proc, busy=700, idle=1500, rx=10, tx=10)  # interface counters reset
    third = sampler.sample()
    assert third["net_rx_bps"] is None and third["net_tx_bps"] is None


@pytest.mark.skipif(not os.path.exists("/proc/stat"), reason="needs a Linux /proc (runs in CI)")
def test_readers_work_on_this_linux_machine(storage_root):
    """The fake files above follow the kernel's format; this checks it against a real kernel."""
    import time
    busy, total = read_cpu_times()
    assert 0 <= busy <= total
    memory = read_memory()
    assert memory["total"] > 0 and 0 <= memory["used"] <= memory["total"]
    assert len(system_metrics.read_loadavg()) == 3
    assert system_metrics.read_uptime() > 0

    sampler = MetricsSampler(storage_path=storage_root)
    sampler.sample()
    time.sleep(0.2)
    second = sampler.sample()
    assert second["cpu_percent"] is not None and 0 <= second["cpu_percent"] <= 100
    assert second["mem_total"] == memory["total"]


# ── Storage, rollup, pruning ──────────────────────────────────────────────

HOUR = 1_700_002_800  # a UTC hour boundary (divisible by 3600)


def sample_row(ts, cpu, temp=50.0):
    return {"ts": ts, "cpu_percent": cpu, "load_1": 0.5, "mem_used": 1000, "mem_total": 2000,
            "swap_used": 0, "temp_c": temp, "net_rx_bps": 10.0, "net_tx_bps": 5.0,
            "disk_used": 500, "disk_total": 1000}


def test_rollup_averages_complete_hours_once(clean_db, db_session):
    for minute, cpu in enumerate([10.0, 20.0, 60.0]):
        store_sample(db_session, sample_row(HOUR + minute * 60 + 7, cpu, temp=40.0 + minute))
    store_sample(db_session, sample_row(HOUR + 3600 + 5, 99.0))  # the current, incomplete hour
    db_session.commit()

    roll_up_hours(db_session, now=HOUR + 3600 + 30)
    roll_up_hours(db_session, now=HOUR + 3600 + 90)  # idempotent
    db_session.commit()

    rows = db_session.query(SystemMetricsHourly).all()
    assert len(rows) == 1
    hour = rows[0]
    assert hour.ts == HOUR and hour.samples == 3
    assert hour.cpu_percent == pytest.approx(30.0)
    assert hour.cpu_max == 60.0
    assert hour.temp_max == 42.0
    assert hour.mem_used == 1000


def test_store_sample_keeps_one_row_per_minute(clean_db, db_session):
    store_sample(db_session, sample_row(HOUR + 5, 10.0))
    store_sample(db_session, sample_row(HOUR + 50, 20.0))
    db_session.commit()
    rows = db_session.query(SystemMetricsMinute).all()
    assert [(r.ts, r.cpu_percent) for r in rows] == [(HOUR, 20.0)]


def test_prune_drops_old_rows(clean_db, db_session):
    now = HOUR + 40 * 86400
    store_sample(db_session, sample_row(now - 26 * 3600, 1.0))  # older than a day: dropped
    store_sample(db_session, sample_row(now - 60, 2.0))
    db_session.add(SystemMetricsHourly(ts=HOUR, samples=1))  # 40 days old: dropped
    db_session.add(SystemMetricsHourly(ts=now - 2 * 86400 // 3600 * 3600, samples=1))
    db_session.commit()

    prune(db_session, now)
    db_session.commit()
    assert [r.cpu_percent for r in db_session.query(SystemMetricsMinute)] == [2.0]
    assert db_session.query(SystemMetricsHourly).count() == 1


# ── API ───────────────────────────────────────────────────────────────────

def test_now_reports_live_values(client):
    r = client.get("/api/system/now")
    assert r.status_code == 200
    body = r.json()
    assert body["hostname"]
    assert body["disk"]["total"] > 0 and 0 <= body["disk"]["percent"] <= 100
    assert body["cpu"]["cores"] >= 1
    assert body["uptime"]["backend_seconds"] >= 0
    assert body["services"]["api_token_enabled"] is False
    assert body["sampler_running"] is False  # SYNAPS_METRICS_INTERVAL=0 in tests


def test_history_uses_minutes_then_hours(client, clean_db, db_session):
    import time
    now = int(time.time())
    store_sample(db_session, sample_row(now - 120, 15.0))
    store_sample(db_session, sample_row(now - 2 * 86400, 80.0))  # outside 24h
    db_session.add(SystemMetricsHourly(ts=(now - 3 * 86400) // 3600 * 3600, samples=60,
                                       cpu_percent=25.0, cpu_max=70.0))
    db_session.commit()

    day = client.get("/api/system/history?range=24h").json()
    assert day["resolution_seconds"] == 60
    assert [p["cpu_percent"] for p in day["points"]] == [15.0]
    assert "cpu_max" not in day["points"][0]
    assert day["collecting_since"] <= now - 3 * 86400

    week = client.get("/api/system/history?range=7d").json()
    assert week["resolution_seconds"] == 3600
    assert week["points"][0]["cpu_max"] == 70.0

    assert client.get("/api/system/history?range=2y").status_code == 422


def test_history_empty_before_collection(client, clean_db):
    body = client.get("/api/system/history?range=1h").json()
    assert body["points"] == [] and body["collecting_since"] is None


def upload(client, data, path, source_id, name="Test device"):
    params = urlencode({
        "source_id": source_id, "original_path": path, "original_filename": os.path.basename(path),
        "source_location": "Photos", "client_sha256": sha256_hex(data),
    })
    r = client.put("/api/v2/ingest/stream?" + params, content=data)
    assert r.status_code == 200, r.text
    return r.json()


@pytest.fixture
def backed_up(client, clean_db, db_session):
    """Two devices: the iPhone uploads two photos (one yesterday), the Mac uploads one of them again."""
    from models_v2 import LogicalItem, Source

    photo = make_jpeg_bytes() + os.urandom(8)
    other = make_jpeg_bytes(color=(10, 200, 10)) + os.urandom(8)
    upload(client, photo, "Camera Roll/IMG_1.JPG", "iphone_test")
    upload(client, other, "Camera Roll/IMG_2.JPG", "iphone_test")
    upload(client, photo, "/Users/x/Pictures/IMG_1.JPG", "mac_test")

    yesterday_noon = datetime.combine(date.today() - timedelta(days=1), datetime.min.time()) + timedelta(hours=12)
    yesterday_utc = yesterday_noon.astimezone(timezone.utc).replace(tzinfo=None)
    from models_v2 import PhysicalObject
    db_session.query(LogicalItem).filter(LogicalItem.original_filename == "IMG_2.JPG").update(
        {"imported_at": yesterday_utc})
    db_session.query(PhysicalObject).filter(PhysicalObject.sha256 == sha256_hex(other)).update(
        {"created_at": yesterday_utc})
    db_session.query(Source).filter(Source.id == "iphone_test").update({"friendly_name": "Harsh's iPhone"})
    db_session.commit()
    return {"photo": len(photo), "other": len(other)}


def test_backups_per_local_day_and_device(client, backed_up):
    body = client.get("/api/system/backups?days=7").json()
    assert body["days"] == 7 and len(body["series"]) == 7
    assert body["devices"]["iphone_test"] == "Harsh's iPhone"

    today, yesterday = body["series"][-1], body["series"][-2]
    assert today["date"] == date.today().isoformat()
    assert today["files"] == 2 and today["bytes"] == 2 * backed_up["photo"]
    assert today["by_device"]["mac_test"] == {"files": 1, "bytes": backed_up["photo"]}
    assert yesterday["files"] == 1 and yesterday["bytes"] == backed_up["other"]
    # the Mac's copy of IMG_1 was already on the NAS: uploaded, but no new data stored
    assert (today["new_files"], today["new_bytes"]) == (1, backed_up["photo"])
    assert (yesterday["new_files"], yesterday["new_bytes"]) == (1, backed_up["other"])
    assert all(day["files"] == 0 for day in body["series"][:-2])


def test_devices_list_last_backup(client, backed_up):
    devices = {d["id"]: d for d in client.get("/api/system/devices").json()["devices"]}
    assert devices["iphone_test"]["files"] == 2
    assert devices["iphone_test"]["bytes"] == backed_up["photo"] + backed_up["other"]
    assert devices["mac_test"]["files"] == 1
    for d in devices.values():
        assert d["last_backup_at"].endswith("Z")


def test_activity_pages_newest_first(client, backed_up):
    first = client.get("/api/system/activity?limit=2").json()
    assert len(first["items"]) == 2 and first["next_before"]
    assert first["items"][0]["imported_at"] >= first["items"][1]["imported_at"]

    second = client.get("/api/system/activity", params={"limit": 2, "before": first["next_before"]}).json()
    assert [i["filename"] for i in second["items"]] == ["IMG_2.JPG"]  # yesterday's upload is oldest
    assert second["next_before"] is None
    seen = {i["id"] for i in first["items"]} | {i["id"] for i in second["items"]}
    assert len(seen) == 3

    assert client.get("/api/system/activity?before=garbage").status_code == 400


def test_storage_counts_dedup_savings(client, backed_up):
    vault = client.get("/api/system/storage").json()["vault"]
    assert vault["stored_files"] == 2
    assert vault["by_kind"]["photos"]["files"] == 2
    assert vault["uploaded_files"] == 3
    assert vault["dedup_saved_bytes"] == backed_up["photo"]


def test_contact_time_is_utc(client, backed_up, db_session):
    """A device's check-in (the pre-upload check) records its contact time in UTC, like every other v2 time."""
    from models_v2 import Source
    source = {"id": "iphone_test", "friendly_name": "Harsh's iPhone", "platform": "iOS"}
    r = client.post("/api/v2/ingest/check", json={"source": source, "files": []})
    assert r.status_code == 200, r.text
    db_session.expire_all()
    seen = db_session.get(Source, "iphone_test").last_seen_at
    assert abs(seen - datetime.now(timezone.utc).replace(tzinfo=None)) < timedelta(minutes=1)


def test_backups_count_an_upload_stored_at_the_window_start(client, backed_up, db_session):
    """SQLite's default writes '2026-10-13 18:30:00' (no fraction); it must still be in the window."""
    from sqlalchemy import text
    from routers.system import _local_day_start_utc

    start = date.today() - timedelta(days=6)
    stamp = _local_day_start_utc(start).strftime("%Y-%m-%d %H:%M:%S")
    db_session.execute(text("UPDATE logical_items SET imported_at = :t WHERE original_filename = 'IMG_2.JPG'"), {"t": stamp})
    db_session.commit()

    series = client.get("/api/system/backups?days=7").json()["series"]
    assert series[0]["date"] == start.isoformat()
    assert series[0]["files"] == 1
