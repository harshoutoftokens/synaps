"""
Synaps system metrics for the stats dashboard.

A daemon thread samples CPU, memory, temperature, network and disk once a minute by reading
Linux's /proc and /sys files directly: no extra dependency to build for the Core 2 Duo, and
each read takes microseconds. Samples are kept per minute for a day and rolled up into hourly
averages for METRICS_HOURLY_RETENTION_DAYS. On a machine without these files (a Mac during
development) every reader returns None and the API reports the value as unavailable.
"""
import logging
import os
import shutil
import threading
import time

from sqlalchemy import Column, Float, Integer, func, text
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.orm import Session

from config import METRICS_HOURLY_RETENTION_DAYS, STORAGE_PATH
from database import Base

logger = logging.getLogger("synaps.metrics")

PROCESS_STARTED_AT = time.time()

# One extra hour of minute rows, so the hour being rolled up is always complete
MINUTE_RETENTION_SECONDS = 25 * 3600

# Interfaces whose traffic is virtual or already counted on a physical interface
_VIRTUAL_IFACE_PREFIXES = ("lo", "docker", "veth", "br-", "virbr", "tailscale", "tun", "wg")
# hwmon drivers and thermal zone types that report the CPU's temperature
_CPU_HWMON_NAMES = {"coretemp", "k10temp", "zenpower", "cpu_thermal"}
_CPU_THERMAL_TYPES = {"x86_pkg_temp", "acpitz", "cpu-thermal", "cpu_thermal", "soc_thermal"}


class SystemMetricsMinute(Base):
    """One sample per minute (UTC unix seconds at the start of the minute)."""
    __tablename__ = "system_metrics_minute"

    ts = Column(Integer, primary_key=True)
    cpu_percent = Column(Float)
    load_1 = Column(Float)
    mem_used = Column(Integer)
    mem_total = Column(Integer)
    swap_used = Column(Integer)
    temp_c = Column(Float)
    net_rx_bps = Column(Float)
    net_tx_bps = Column(Float)
    disk_used = Column(Integer)
    disk_total = Column(Integer)


class SystemMetricsHourly(Base):
    """Hourly averages (and peaks) of the minute samples (UTC unix seconds at the start of the hour)."""
    __tablename__ = "system_metrics_hourly"

    ts = Column(Integer, primary_key=True)
    samples = Column(Integer, nullable=False, default=0)
    cpu_percent = Column(Float)
    cpu_max = Column(Float)
    load_1 = Column(Float)
    mem_used = Column(Integer)
    mem_total = Column(Integer)
    swap_used = Column(Integer)
    temp_c = Column(Float)
    temp_max = Column(Float)
    net_rx_bps = Column(Float)
    net_tx_bps = Column(Float)
    disk_used = Column(Integer)
    disk_total = Column(Integer)


# ── Readers ───────────────────────────────────────────────────────────────

def _read_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def read_cpu_times(proc_root="/proc"):
    """(busy, total) jiffies summed over all CPUs since boot, or None."""
    content = _read_text(os.path.join(proc_root, "stat"))
    if not content:
        return None
    for line in content.splitlines():
        if line.startswith("cpu "):
            try:
                values = [int(v) for v in line.split()[1:]]
                # user nice system idle iowait irq softirq steal; guest time is already in user/nice
                total = sum(values[:8])
                idle = values[3] + (values[4] if len(values) > 4 else 0)
                return total - idle, total
            except (ValueError, IndexError):
                return None
    return None


def read_memory(proc_root="/proc"):
    """Memory and swap in bytes, or None."""
    content = _read_text(os.path.join(proc_root, "meminfo"))
    if not content:
        return None
    info = {}
    for line in content.splitlines():
        key, _, rest = line.partition(":")
        parts = rest.split()
        if parts:
            try:
                info[key] = int(parts[0]) * 1024  # values are in kB
            except ValueError:
                pass
    total = info.get("MemTotal")
    if not total:
        return None
    available = info.get("MemAvailable")
    if available is None:  # kernels before 3.14
        available = info.get("MemFree", 0) + info.get("Buffers", 0) + info.get("Cached", 0)
    swap_total = info.get("SwapTotal", 0)
    return {
        "total": total,
        "available": available,
        "used": max(0, total - available),
        "swap_total": swap_total,
        "swap_used": max(0, swap_total - info.get("SwapFree", 0)),
    }


def read_loadavg(proc_root="/proc"):
    """(1, 5, 15)-minute load averages, or None."""
    content = _read_text(os.path.join(proc_root, "loadavg"))
    try:
        return tuple(float(v) for v in content.split()[:3]) if content else None
    except ValueError:
        return None


def read_uptime(proc_root="/proc"):
    """Seconds since boot, or None."""
    content = _read_text(os.path.join(proc_root, "uptime"))
    try:
        return float(content.split()[0]) if content else None
    except (ValueError, IndexError):
        return None


def read_network_bytes(proc_root="/proc"):
    """(received, sent) bytes since boot, summed over physical interfaces, or None."""
    content = _read_text(os.path.join(proc_root, "net", "dev"))
    if not content:
        return None
    rx = tx = 0
    found = False
    for line in content.splitlines()[2:]:
        name, sep, data = line.partition(":")
        name = name.strip()
        if not sep or name.startswith(_VIRTUAL_IFACE_PREFIXES):
            continue
        fields = data.split()
        try:
            rx += int(fields[0])
            tx += int(fields[8])
            found = True
        except (ValueError, IndexError):
            continue
    return (rx, tx) if found else None


def _plausible_celsius(raw):
    try:
        value = int(raw.strip()) / 1000
    except (ValueError, AttributeError):
        return None
    return value if 0 < value < 150 else None


def read_cpu_temperature(sys_root="/sys"):
    """Hottest CPU sensor in °C, or None when the hardware exposes none.
    Prefers hwmon drivers (coretemp covers Intel CPUs back to the Core 2), then thermal zones."""
    temps = []
    hwmon_dir = os.path.join(sys_root, "class", "hwmon")
    try:
        hwmons = sorted(os.listdir(hwmon_dir))
    except OSError:
        hwmons = []
    for entry in hwmons:
        base = os.path.join(hwmon_dir, entry)
        if (_read_text(os.path.join(base, "name")) or "").strip() not in _CPU_HWMON_NAMES:
            continue
        try:
            files = os.listdir(base)
        except OSError:
            continue
        for name in files:
            if name.startswith("temp") and name.endswith("_input"):
                value = _plausible_celsius(_read_text(os.path.join(base, name)))
                if value is not None:
                    temps.append(value)
    if temps:
        return round(max(temps), 1)

    thermal_dir = os.path.join(sys_root, "class", "thermal")
    try:
        zones = sorted(z for z in os.listdir(thermal_dir) if z.startswith("thermal_zone"))
    except OSError:
        zones = []
    for zone in zones:
        base = os.path.join(thermal_dir, zone)
        if (_read_text(os.path.join(base, "type")) or "").strip() in _CPU_THERMAL_TYPES:
            value = _plausible_celsius(_read_text(os.path.join(base, "temp")))
            if value is not None:
                temps.append(value)
    return round(max(temps), 1) if temps else None


def read_disk(path=STORAGE_PATH):
    """(total, used, free) bytes for the volume holding `path`, or None."""
    try:
        usage = shutil.disk_usage(path)
        return usage.total, usage.used, usage.free
    except OSError:
        return None


# ── Sampling ──────────────────────────────────────────────────────────────

class MetricsSampler:
    """Takes samples. CPU use and network speed are rates, so each comes from the difference
    with the previous sample; the first sample after start has them as None."""

    def __init__(self, proc_root="/proc", sys_root="/sys", storage_path=STORAGE_PATH,
                 clock=time.time, monotonic=time.monotonic):
        self.proc_root = proc_root
        self.sys_root = sys_root
        self.storage_path = storage_path
        self._clock = clock
        self._monotonic = monotonic
        self._prev = None  # (monotonic, cpu_times, network_bytes)
        self._lock = threading.Lock()
        self.latest = None

    def sample(self) -> dict:
        with self._lock:
            now = self._monotonic()
            cpu = read_cpu_times(self.proc_root)
            net = read_network_bytes(self.proc_root)
            cpu_percent = rx_bps = tx_bps = None
            if self._prev is not None:
                prev_time, prev_cpu, prev_net = self._prev
                elapsed = now - prev_time
                if cpu and prev_cpu and cpu[1] > prev_cpu[1]:
                    busy = (cpu[0] - prev_cpu[0]) / (cpu[1] - prev_cpu[1])
                    cpu_percent = round(min(max(busy * 100, 0.0), 100.0), 1)
                # A counter that went backwards (interface reset) gives no reading, not a negative one
                if net and prev_net and elapsed > 0 and net[0] >= prev_net[0] and net[1] >= prev_net[1]:
                    rx_bps = round((net[0] - prev_net[0]) / elapsed, 1)
                    tx_bps = round((net[1] - prev_net[1]) / elapsed, 1)
            self._prev = (now, cpu, net)

            memory = read_memory(self.proc_root)
            load = read_loadavg(self.proc_root)
            disk = read_disk(self.storage_path)
            row = {
                "ts": int(self._clock()),
                "cpu_percent": cpu_percent,
                "load_1": load[0] if load else None,
                "mem_used": memory["used"] if memory else None,
                "mem_total": memory["total"] if memory else None,
                "swap_used": memory["swap_used"] if memory else None,
                "temp_c": read_cpu_temperature(self.sys_root),
                "net_rx_bps": rx_bps,
                "net_tx_bps": tx_bps,
                "disk_used": disk[1] if disk else None,
                "disk_total": disk[0] if disk else None,
            }
            self.latest = row
            return row


def store_sample(db: Session, row: dict) -> None:
    """Save a sample as its minute's row (a second sample in the same minute replaces it)."""
    minute = dict(row, ts=row["ts"] // 60 * 60)
    statement = sqlite_insert(SystemMetricsMinute).values(**minute)
    db.execute(statement.on_conflict_do_update(
        index_elements=["ts"], set_={k: v for k, v in minute.items() if k != "ts"}))


def roll_up_hours(db: Session, now: float) -> None:
    """Average every complete hour of minute samples not yet in the hourly table."""
    current_hour = int(now) // 3600 * 3600
    last_done = db.query(func.max(SystemMetricsHourly.ts)).scalar()
    since = last_done + 3600 if last_done is not None else 0
    db.execute(
        text(
            "INSERT OR IGNORE INTO system_metrics_hourly "
            "(ts, samples, cpu_percent, cpu_max, load_1, mem_used, mem_total, swap_used, "
            " temp_c, temp_max, net_rx_bps, net_tx_bps, disk_used, disk_total) "
            "SELECT (ts / 3600) * 3600 AS hour, COUNT(*), AVG(cpu_percent), MAX(cpu_percent), "
            "AVG(load_1), CAST(AVG(mem_used) AS INTEGER), MAX(mem_total), "
            "CAST(AVG(swap_used) AS INTEGER), AVG(temp_c), MAX(temp_c), AVG(net_rx_bps), "
            "AVG(net_tx_bps), MAX(disk_used), MAX(disk_total) "
            "FROM system_metrics_minute WHERE ts >= :since AND ts < :current_hour "
            "GROUP BY hour"
        ),
        {"since": since, "current_hour": current_hour},
    )


def prune(db: Session, now: float) -> None:
    db.query(SystemMetricsMinute).filter(
        SystemMetricsMinute.ts < now - MINUTE_RETENTION_SECONDS
    ).delete(synchronize_session=False)
    db.query(SystemMetricsHourly).filter(
        SystemMetricsHourly.ts < now - METRICS_HOURLY_RETENTION_DAYS * 86400
    ).delete(synchronize_session=False)


# ── Background thread ─────────────────────────────────────────────────────

sampler = MetricsSampler()
_started = False
_start_lock = threading.Lock()


def _sampler_loop(interval: int) -> None:
    from database import SessionLocal
    from thumbnails import lower_thread_priority

    lower_thread_priority()
    sampler.sample()  # prime the CPU and network counters
    while True:
        time.sleep(interval)
        try:
            row = sampler.sample()
            with SessionLocal() as db:
                store_sample(db, row)
                roll_up_hours(db, row["ts"])
                prune(db, row["ts"])
                db.commit()
        except Exception:
            logger.exception("Could not record system metrics")


def start_sampler(interval: int) -> bool:
    """Start the sampling thread once. An interval of 0 or less leaves it off."""
    global _started
    if interval <= 0:
        return False
    with _start_lock:
        if _started:
            return True
        _started = True
    threading.Thread(target=_sampler_loop, args=(interval,), name="synaps-metrics", daemon=True).start()
    return True


def current_snapshot(max_age: float) -> dict:
    """The sampler's latest sample when it is fresh, otherwise a new reading taken now
    (without CPU use or network speed, which need two readings)."""
    latest = sampler.latest
    if latest is not None and time.time() - latest["ts"] <= max_age:
        return latest
    return MetricsSampler(storage_path=sampler.storage_path).sample()
