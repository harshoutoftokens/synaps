'use client';

import { useEffect, useMemo, useState } from 'react';
import {
  Activity, AlertTriangle, CheckCircle2, Clock, Cpu, HardDrive, Laptop, MemoryStick, Monitor,
  Network, Smartphone, Thermometer, Upload, Database, XCircle,
} from 'lucide-react';
import { TopBar } from '@/components/TopBar';
import { GlassSegmentedControl } from '@/components/glass/GlassSegmentedControl';
import { DayBars, Figure, Ring, Sparkline, StorageBar, Tile, type TileState } from '@/components/dashboard/Widgets';
import {
  STALE_DEVICE_DAYS, bytesParts, daysSince, formatBytes, formatClock, formatCount, formatDuration,
  formatRate, formatWhen, getActivity, getBackupHistory, getDevices, getStorage, getSystemHistory,
  getSystemNow, parseUtc, usePolling, type ActivityItem, type Device, type HistoryRange, type MetricPoint,
  type SystemHistory, type SystemNow,
} from '@/lib/system';

const RANGES: { key: HistoryRange; label: string; seconds: number }[] = [
  { key: '24h', label: '24 hours', seconds: 86400 },
  { key: '7d', label: '7 days', seconds: 7 * 86400 },
  { key: '30d', label: '30 days', seconds: 30 * 86400 },
];

interface Problem {
  level: 'warn' | 'crit';
  text: string;
}

/** What needs the owner's attention, most serious first. */
function findProblems(now: SystemNow | null, nowError: Error | null, devices: Device[] | null, lastGood: number | null): Problem[] {
  const problems: Problem[] = [];
  if (nowError) {
    problems.push({
      level: 'crit',
      text: lastGood
        ? `Can't reach the NAS. Showing what it reported at ${formatClock(lastGood)}.`
        : "Can't reach the NAS. Check that it's on and connected.",
    });
  }
  const percent = now?.disk.percent;
  if (percent != null && percent >= 95) {
    problems.push({ level: 'crit', text: `Disk is ${Math.round(percent)}% full: ${formatBytes(now!.disk.free)} left.` });
  } else if (percent != null && percent >= 85) {
    problems.push({ level: 'warn', text: `Disk is ${Math.round(percent)}% full: ${formatBytes(now!.disk.free)} left.` });
  }
  for (const device of devices ?? []) {
    const days = daysSince(parseUtc(device.last_backup_at));
    if (days != null && days >= STALE_DEVICE_DAYS) {
      problems.push({ level: 'warn', text: `${device.name} hasn't backed up in ${days} days.` });
    }
  }
  return problems.sort((a, b) => (a.level === b.level ? 0 : a.level === 'crit' ? -1 : 1));
}

/**
 * Months until the disk is full, from the growth over the hourly history (least squares).
 * Null until there are at least three days of samples; Infinity when the disk isn't growing.
 */
function monthsUntilFull(history: SystemHistory | null, free: number | null): number | null {
  const points = (history?.points ?? []).filter((p) => p.disk_used != null);
  if (free == null || points.length < 2 || points[points.length - 1].t - points[0].t < 3 * 86400) return null;
  const n = points.length;
  const meanT = points.reduce((s, p) => s + p.t, 0) / n;
  const meanV = points.reduce((s, p) => s + (p.disk_used as number), 0) / n;
  let num = 0;
  let den = 0;
  for (const p of points) {
    num += (p.t - meanT) * ((p.disk_used as number) - meanV);
    den += (p.t - meanT) ** 2;
  }
  const bytesPerSecond = den ? num / den : 0;
  if (bytesPerSecond <= 0) return Infinity;
  return free / bytesPerSecond / (30 * 86400);
}

function series(history: SystemHistory | null, pick: (p: MetricPoint) => number | null) {
  return (history?.points ?? []).map((p) => ({ t: p.t, v: pick(p) }));
}

function DeviceIcon({ platform }: { platform: string }) {
  const p = platform.toLowerCase();
  const Icon = p.includes('ios') || p.includes('iphone') ? Smartphone : p.includes('mac') ? Laptop : Monitor;
  return <Icon size={16} className="text-[var(--w-text-2)] shrink-0" aria-hidden />;
}

export default function Dashboard() {
  const [range, setRange] = useState<HistoryRange>('24h');
  const rangeSeconds = RANGES.find((r) => r.key === range)!.seconds;
  const rangeLabel = RANGES.find((r) => r.key === range)!.label;

  const now = usePolling(getSystemNow, 10_000);
  const history = usePolling(() => getSystemHistory(range), 60_000, [range]);
  const month = usePolling(() => getSystemHistory('30d'), 10 * 60_000);
  const backups = usePolling(() => getBackupHistory(30), 5 * 60_000);
  const devices = usePolling(getDevices, 60_000);
  const storage = usePolling(getStorage, 5 * 60_000);

  const n = now.data;
  const problems = findProblems(n, now.error, devices.data?.devices ?? null, now.updatedAt);
  const attention: TileState = problems.some((p) => p.level === 'crit') ? 'crit' : problems.length ? 'warn' : 'ok';
  const diskPercent = n?.disk.percent ?? null;
  const diskState: TileState = diskPercent == null ? 'ok' : diskPercent >= 95 ? 'crit' : diskPercent >= 85 ? 'warn' : 'ok';
  const fullIn = monthsUntilFull(month.data, n?.disk.free ?? null);

  // One time window for every sparkline in the chosen range
  const to = n?.sampled_at ?? Math.floor(Date.now() / 1000);
  const from = to - rangeSeconds;
  const collectingSince = history.data?.collecting_since ?? null;
  const tempPeak = useMemo(() => {
    const temps = (history.data?.points ?? []).map((p) => p.temp_max ?? p.temp_c).filter((v): v is number => v != null);
    return temps.length ? Math.max(...temps) : null;
  }, [history.data]);

  // What a tile says when there is no live reading: history may still exist below it
  const missing = n ? 'Unknown' : now.error ? 'Unavailable' : 'Loading…';
  const hasHistory = (pick: (p: MetricPoint) => number | null) => (history.data?.points ?? []).some((p) => pick(p) != null);
  const noLive = (pick: (p: MetricPoint) => number | null) =>
    !n ? '—' : hasHistory(pick) ? 'No live reading · history below' : 'Not measured on this machine';

  const today = backups.data?.series[backups.data.series.length - 1] ?? null;
  const monthFiles = backups.data?.series.reduce((sum, d) => sum + d.files, 0) ?? null;
  const vault = storage.data?.vault;

  const [usedValue, usedUnit] = bytesParts(n?.memory.used);
  const [diskFree, diskFreeUnit] = bytesParts(n?.disk.free);
  const [rxValue, rxUnit] = bytesParts(n?.network.rx_bps);

  // At most two problems fit the tile. Offline and disk always come first, so anything past
  // them is a late device, which the Devices tile lists.
  const shownProblems = problems.slice(0, 2);
  const rest = problems.slice(2);

  const rangeControl = (
    <GlassSegmentedControl
      options={RANGES.map(({ key, label }) => ({ key, label }))}
      value={range}
      onChange={(key) => setRange(key as HistoryRange)}
    />
  );

  return (
    <div className="dashboard">
      <TopBar
        title="Home Cloud"
        subtitle={n ? `${n.hostname} · checked ${formatClock(now.updatedAt)}` : now.error ? 'NAS unreachable' : 'Connecting…'}
      >
        <div className="hidden sm:flex items-center gap-2 mr-1">
          <span className="w-caption">System charts</span>
          {rangeControl}
        </div>
      </TopBar>

      {/* On a phone the range control gets its own row so the title keeps its width */}
      <div className="sm:hidden px-4 pb-3 flex items-center justify-center gap-2">
        <span className="w-caption">Charts</span>
        {rangeControl}
      </div>

      <div className="widgets-area px-4 lg:px-6 pb-10">
        <div className="widgets">
          {/* Disk: reports its state in the ring and label; the whole-tile tint is Needs attention's */}
          <Tile title="Disk" icon={HardDrive} size="large" accent={diskState}>
            <div className="flex-1 flex items-center gap-5">
              <Ring percent={diskPercent} state={diskState}>
                <span className="text-[30px] font-semibold w-tabular">{diskPercent == null ? '—' : `${Math.round(diskPercent)}%`}</span>
              </Ring>
              <div className="min-w-0">
                <Figure value={n?.disk.free == null ? null : diskFree} unit={`${diskFreeUnit} free`} missing={missing} className="!text-[40px]" />
                <p className="w-caption mt-2">
                  {formatBytes(n?.disk.used)} of {formatBytes(n?.disk.total)} used
                </p>
              </div>
            </div>
            <Sparkline points={series(month.data, (p) => p.disk_used)} from={to - 30 * 86400} to={to}
              fit label="Disk used, last 30 days" format={(v) => formatBytes(v)} height={34} />
            <p className="w-caption mt-1.5">
              {fullIn == null
                ? 'Estimating when it fills up after 3 days of data'
                : fullIn === Infinity
                  ? 'Not growing over the last 30 days'
                  : fullIn < 1
                    ? 'Full in less than a month at the 30-day rate'
                    : `Full in about ${Math.round(fullIn)} ${Math.round(fullIn) === 1 ? 'month' : 'months'} at the 30-day rate`}
            </p>
          </Tile>

          {/* Needs attention: the whole tile takes the state colour */}
          <Tile title={attention === 'ok' ? 'All good' : 'Needs attention'} icon={attention === 'ok' ? CheckCircle2 : AlertTriangle}
            size="wide" state={attention}>
            {problems.length ? (
              <ul className="mt-auto space-y-1">
                {shownProblems.map((p) => (
                  <li key={p.text} className={`${problems.length > 1 ? 'text-[15px]' : 'text-[17px]'} font-semibold leading-snug`}>{p.text}</li>
                ))}
                {rest.length === 1 && <li className="w-caption">{rest[0].text}</li>}
                {rest.length > 1 && (
                  <li className="w-caption">{rest.length} more devices are late. See Devices.</li>
                )}
              </ul>
            ) : (
              <div className="mt-auto">
                <p className="text-[17px] font-semibold leading-snug">
                  {n ? 'Disk, devices and the NAS look healthy.' : 'Checking the NAS…'}
                </p>
                {n && !n.services.api_token_enabled && (
                  <p className="w-caption mt-1">The API token is off: anyone on the home Wi-Fi can use the API.</p>
                )}
              </div>
            )}
          </Tile>

          {/* CPU */}
          <Tile title="CPU" icon={Cpu}>
            <Figure className="mt-auto" value={n?.cpu.percent == null ? null : String(Math.round(n.cpu.percent))} unit="%" missing={missing} />
            <p className="w-caption mt-1">
              {n?.cpu.percent == null && !n?.cpu.load
                ? noLive((p) => p.cpu_percent)
                : `Load ${n?.cpu.load ? n.cpu.load[0].toFixed(2) : '—'} · ${n?.cpu.cores ?? '—'} cores`}
            </p>
            <Sparkline points={series(history.data, (p) => p.cpu_percent)} from={from} to={to} max={100} height={34}
              label={`CPU use, last ${rangeLabel}`} format={(v) => `${Math.round(v)}%`} />
          </Tile>

          {/* Memory */}
          <Tile title="Memory" icon={MemoryStick}>
            <Figure className="mt-auto" value={n?.memory.used == null ? null : usedValue} unit={usedUnit} missing={missing} />
            <p className="w-caption mt-1">
              {n?.memory.total == null
                ? noLive((p) => p.mem_used)
                // Swap doesn't fit a small tile reliably; climbing swap becomes a Needs-attention rule (#97 phase 4)
                : `of ${formatBytes(n.memory.total, 0)}`}
            </p>
            <Sparkline points={series(history.data, (p) => p.mem_used)} from={from} to={to}
              max={n?.memory.total ?? undefined} height={34}
              label={`Memory used, last ${rangeLabel}`} format={(v) => formatBytes(v)} />
          </Tile>

          {/* Temperature: grey line; no threshold is set until the NAS's real sensor range is known */}
          <Tile title="Temperature" icon={Thermometer}>
            <Figure className="mt-auto" value={n?.temperature_c == null ? null : String(Math.round(n.temperature_c))} unit="°C" missing={missing} />
            <p className="w-caption mt-1">
              {n?.temperature_c == null
                ? !n ? '—' : hasHistory((p) => p.temp_c) ? 'No live reading · history below' : 'No CPU sensor readable'
                : tempPeak != null ? `Peak ${Math.round(tempPeak)}° in ${rangeLabel}` : 'CPU'}
            </p>
            <Sparkline points={series(history.data, (p) => p.temp_c)} from={from} to={to} height={34}
              label={`CPU temperature, last ${rangeLabel}`} format={(v) => `${Math.round(v)}°C`} />
          </Tile>

          {/* Network */}
          <Tile title="Network" icon={Network}>
            <Figure className="mt-auto" value={n?.network.rx_bps == null ? null : rxValue} unit={`${rxUnit}/s`} missing={missing} />
            <p className="w-caption mt-1">
              {n?.network.tx_bps == null ? noLive((p) => p.net_rx_bps) : `In · ${formatRate(n.network.tx_bps)} out`}
            </p>
            <Sparkline points={series(history.data, (p) => p.net_rx_bps)} from={from} to={to} height={34}
              label={`Network in, last ${rangeLabel}`} format={(v) => formatRate(v)} />
          </Tile>

          {/* Today */}
          <Tile title="Backed up today" icon={Upload} size="wide">
            <Figure className="mt-auto" value={today ? formatCount(today.files) : null} unit="files" missing={missing} />
            <p className="w-caption mt-1.5">
              {today
                ? today.files
                  ? `${formatBytes(today.bytes)} · ${formatCount(today.new_files)} new, ${formatCount(today.files - today.new_files)} already on the NAS`
                  : 'Nothing yet today'
                : '—'}
            </p>
          </Tile>

          {/* Devices */}
          <Tile title="Devices" icon={Smartphone} size="large">
            <DeviceList devices={devices.data?.devices ?? null} />
          </Tile>

          {/* Backups per day */}
          <Tile title="Backed up per day" icon={Upload} size="large"
            aside={<span className="w-caption">Last 30 days</span>}>
            <Figure className="mt-3" value={monthFiles == null ? null : formatCount(monthFiles)} unit="files" missing={missing} />
            <div className="flex-1 flex flex-col justify-end mt-4">
              {backups.data ? <DayBars days={backups.data.series} height={188} /> : null}
            </div>
          </Tile>

          {/* Storage: greyscale; colour is kept for state */}
          <Tile title="Vault" icon={Database} size="wide"
            aside={vault && vault.dedup_saved_bytes > 0 ? <span className="w-caption">{formatBytes(vault.dedup_saved_bytes)} saved by storing duplicates once</span> : undefined}>
            <Figure className="mt-auto" value={vault ? bytesParts(vault.stored_bytes)[0] : null}
              unit={`${bytesParts(vault?.stored_bytes)[1]} · ${formatCount(vault?.stored_files)} files`} missing={missing} />
            <div className="mt-3">
              <StorageBar parts={[
                { label: 'Photos', bytes: vault?.by_kind.photos.bytes ?? 0, color: 'var(--w-text)' },
                { label: 'Videos', bytes: vault?.by_kind.videos.bytes ?? 0, color: 'var(--w-grey-1)' },
                { label: 'Other', bytes: vault?.by_kind.other.bytes ?? 0, color: 'var(--w-grey-2)' },
              ]} />
            </div>
          </Tile>

          {/* Uptime */}
          <Tile title="Uptime" icon={Clock}>
            <Figure className="mt-auto" value={n?.uptime.system_seconds == null ? null : formatDuration(n.uptime.system_seconds).split(' ')[0]}
              unit={formatDuration(n?.uptime.system_seconds).split(' ')[1]} missing={missing} />
            <p className="w-caption mt-1">{n ? `Synaps up ${formatDuration(n.uptime.backend_seconds)}` : '—'}</p>
          </Tile>

          {/* Services */}
          <Tile title="Synaps" icon={Activity}>
            <dl className="mt-auto space-y-1 w-caption">
              <div className="flex justify-between gap-2"><dt>Thumbnails queued</dt><dd className="text-[var(--w-text)]">{formatCount(n?.services.thumbnail_queue)}</dd></div>
              <div className="flex justify-between gap-2"><dt>Library scan</dt><dd className="text-[var(--w-text)]">{n?.services.scan_running == null ? '—' : n.services.scan_running ? 'Running' : 'Idle'}</dd></div>
              <div className="flex justify-between gap-2"><dt>Database</dt><dd className="text-[var(--w-text)]">{formatBytes(n?.services.database_bytes)}</dd></div>
            </dl>
          </Tile>
        </div>

        {collectingSince && to - collectingSince < rangeSeconds && (
          <p className="w-caption mt-4">
            Charts start at {formatWhen(new Date(collectingSince * 1000))}, when the NAS began recording these numbers.
          </p>
        )}

        <RecentActivity />
      </div>
    </div>
  );
}

function DeviceList({ devices }: { devices: Device[] | null }) {
  if (!devices) return <div className="flex-1" />;
  if (!devices.length) {
    return (
      <p className="mt-auto text-[15px] leading-snug">
        No device has backed up yet. Back up from the Synaps app on a Mac or an iPhone and it will appear here.
      </p>
    );
  }
  return (
    <ul className="mt-2 -mx-1 overflow-y-auto no-scrollbar">
      {devices.map((device) => {
        const last = parseUtc(device.last_backup_at);
        const days = daysSince(last);
        const late = days != null && days >= STALE_DEVICE_DAYS;
        return (
          <li key={device.id} className="flex items-center gap-3 px-1 py-2.5 border-b border-[var(--w-rule)] last:border-0">
            <DeviceIcon platform={device.platform} />
            <div className="min-w-0 flex-1">
              <div className="text-[15px] font-semibold truncate">{device.name}</div>
              <div className="w-caption truncate">{formatCount(device.files)} files · {formatBytes(device.bytes)}</div>
            </div>
            <div className="text-right shrink-0">
              <div className={`text-[15px] font-semibold w-tabular ${late ? 'text-[var(--w-amber)]' : ''}`}>{formatWhen(last)}</div>
              <div className={`w-caption ${late ? '!text-[var(--w-amber)]' : ''}`}>
                {last == null ? 'No backups yet' : late ? `${days} days ago` : 'Last backup'}
              </div>
            </div>
          </li>
        );
      })}
    </ul>
  );
}

function RecentActivity() {
  const first = usePolling(() => getActivity(null, 15), 60_000);
  // Everything shown so far, newest first. A refresh only prepends uploads not shown yet, so
  // nothing already listed drops out and older pages continue from the oldest item shown.
  const [items, setItems] = useState<ActivityItem[]>([]);
  const [next, setNext] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    const page = first.data;
    if (!page) return;
    setItems((prev) => {
      if (!prev.length) {
        setNext(page.next_before);
        return page.items;
      }
      const shown = new Set(prev.map((i) => i.id));
      return [...page.items.filter((i) => !shown.has(i.id)), ...prev];
    });
  }, [first.data]);

  const loadMore = () => {
    if (!next || loading) return;
    setLoading(true);
    setError(null);
    getActivity(next, 25)
      .then((page) => {
        setItems((prev) => {
          const shown = new Set(prev.map((i) => i.id));
          return [...prev, ...page.items.filter((i) => !shown.has(i.id))];
        });
        setNext(page.next_before);
      })
      .catch(() => setError("Couldn't load more. Try again."))
      .finally(() => setLoading(false));
  };

  return (
    <section aria-labelledby="activity-title" className="w mt-4 !p-0">
      <h2 id="activity-title" className="w-label px-[18px] pt-4 pb-2">Recent activity</h2>
      {first.data && !items.length ? (
        <p className="px-[18px] pb-5 text-[15px]">No uploads yet.</p>
      ) : (
        <ul>
          {items.map((item) => (
            <li key={item.id} className="grid grid-cols-[112px_minmax(0,1fr)_auto] sm:grid-cols-[132px_160px_minmax(0,1fr)_auto] items-center gap-3 px-[18px] py-2.5 border-t border-[var(--w-rule)] text-[14px]">
              <span className="w-caption w-tabular whitespace-nowrap">{formatWhen(parseUtc(item.imported_at))}</span>
              <span className="hidden sm:block truncate text-[var(--w-text-2)]">{item.device_name ?? item.device_id}</span>
              <span className="truncate" title={item.filename}>{item.filename}</span>
              <span className="w-caption w-tabular text-right">{formatBytes(item.bytes)}</span>
            </li>
          ))}
        </ul>
      )}
      {(next || error) && (
        <div className="px-[18px] py-3 border-t border-[var(--w-rule)] flex items-center gap-3">
          {next && (
            <button onClick={loadMore} disabled={loading}
              className="text-[14px] font-semibold text-[var(--w-link)] disabled:opacity-50">
              {loading ? 'Loading…' : 'Show older uploads'}
            </button>
          )}
          {error && <span className="w-caption flex items-center gap-1"><XCircle size={14} aria-hidden />{error}</span>}
        </div>
      )}
    </section>
  );
}
