'use client';

import { useId, useState } from 'react';
import type { LucideIcon } from 'lucide-react';
import { formatBytes, formatCount, formatDay, formatWhen, type BackupDay } from '@/lib/system';

export type TileState = 'ok' | 'warn' | 'crit';

/**
 * One widget. Sizes follow home-screen widgets: small 1x1, wide 2x1, large 2x2.
 * `state` turns the whole tile amber or red (the dashboard's one signature move, kept for
 * Needs attention); `accent` colours only the label, for a tile that reports a state.
 */
export function Tile({
  title,
  icon: Icon,
  size = 'small',
  state = 'ok',
  accent = 'ok',
  aside,
  children,
}: {
  title: string;
  icon?: LucideIcon;
  size?: 'small' | 'wide' | 'large';
  state?: TileState;
  accent?: TileState;
  aside?: React.ReactNode;
  children: React.ReactNode;
}) {
  const id = useId();
  return (
    <section
      aria-labelledby={id}
      data-state={state}
      data-accent={accent}
      className={`w ${size === 'wide' ? 'w-wide' : size === 'large' ? 'w-large' : ''}`}
    >
      <div className="flex items-center justify-between gap-2">
        <h2 id={id} className="w-label">
          {Icon && <Icon size={14} strokeWidth={2.2} aria-hidden />}
          {title}
        </h2>
        {aside}
      </div>
      {children}
    </section>
  );
}

/** A big tabular figure with a smaller unit after it; a missing reading is said in words. */
export function Figure({
  value,
  unit,
  missing,
  className = '',
}: {
  value?: string | null;
  unit?: string;
  missing?: string;
  className?: string;
}) {
  if (value == null) {
    return <div className={`w-figure w-missing ${className}`}>{missing ?? 'No data yet'}</div>;
  }
  return (
    <div className={`w-figure ${className}`}>
      {value}
      {unit && <span className="w-unit">{unit}</span>}
    </div>
  );
}

interface SparkPoint { t: number; v: number | null }

/**
 * Values over a fixed time window [from, to], so every chart in one range lines up and a gap
 * in collection shows as a gap rather than a stretched line. Hover, focus or the arrow keys
 * read out the value and time at any point.
 */
export function Sparkline({
  points,
  from,
  to,
  max,
  fit = false,
  label,
  format,
  color = 'var(--w-grey-1)',
  height = 40,
}: {
  points: SparkPoint[];
  from: number;
  to: number;
  max?: number;
  /** Scale to the window's own min..max instead of 0..max, for slow changes like disk growth */
  fit?: boolean;
  label: string;
  format: (v: number) => string;
  color?: string;
  height?: number;
}) {
  const gradient = useId();
  const [active, setActive] = useState<number | null>(null);
  const width = 200;
  const known = points.filter((p): p is { t: number; v: number } => p.v != null && p.t >= from);
  if (known.length < 2 || to <= from) {
    return <div style={{ height }} aria-hidden />;
  }
  const values = known.map((p) => p.v);
  const lo = fit ? Math.min(...values) : 0;
  const hiFit = Math.max(...values);
  const top = fit ? (hiFit > lo ? hiFit : lo + 1) : max ?? (hiFit * 1.15 || 1);
  const x = (t: number) => ((t - from) / (to - from)) * width;
  const y = (v: number) => height - 3 - ((Math.min(v, top) - lo) / (top - lo)) * (height - 6);

  // Split into runs at missing values or gaps longer than three expected steps
  const visible = points.filter((p) => p.t >= from);
  const step = (known[known.length - 1].t - known[0].t) / (known.length - 1);
  const runs: { t: number; v: number }[][] = [];
  let run: { t: number; v: number }[] = [];
  let prevT: number | null = null;
  for (const p of visible) {
    const broken = p.v == null || (prevT != null && step > 0 && p.t - prevT > step * 3);
    if (broken && run.length) {
      runs.push(run);
      run = [];
    }
    if (p.v != null) run.push({ t: p.t, v: p.v });
    prevT = p.t;
  }
  if (run.length) runs.push(run);

  const last = known[known.length - 1];
  const point = active == null ? null : known[active];
  const pick = (clientX: number, rect: DOMRect) => {
    const t = from + ((clientX - rect.left) / rect.width) * (to - from);
    let best = 0;
    known.forEach((p, i) => {
      if (Math.abs(p.t - t) < Math.abs(known[best].t - t)) best = i;
    });
    setActive(best);
  };

  return (
    <div
      className="w-spark"
      tabIndex={0}
      role="img"
      aria-label={`${label}: ${format(last.v)} at ${formatWhen(new Date(last.t * 1000))}. Use the arrow keys to read earlier values.`}
      onMouseMove={(e) => pick(e.clientX, e.currentTarget.getBoundingClientRect())}
      onMouseLeave={() => setActive(null)}
      onFocus={() => setActive(known.length - 1)}
      onBlur={() => setActive(null)}
      onKeyDown={(e) => {
        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
        e.preventDefault();
        const i = active ?? known.length - 1;
        setActive(Math.min(known.length - 1, Math.max(0, i + (e.key === 'ArrowLeft' ? -1 : 1))));
      }}
    >
      <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" className="w-full block" style={{ height }} aria-hidden>
        <defs>
          <linearGradient id={gradient} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color} stopOpacity={0.32} />
            <stop offset="100%" stopColor={color} stopOpacity={0} />
          </linearGradient>
        </defs>
        {runs.map((r, i) => {
          const line = r.map((p) => `${x(p.t).toFixed(1)},${y(p.v).toFixed(1)}`).join(' ');
          const area = `${x(r[0].t).toFixed(1)},${height} ${line} ${x(r[r.length - 1].t).toFixed(1)},${height}`;
          return (
            <g key={i}>
              <polygon points={area} fill={`url(#${gradient})`} />
              <polyline points={line} fill="none" stroke={color} strokeWidth={2} vectorEffect="non-scaling-stroke"
                strokeLinejoin="round" strokeLinecap="round" />
            </g>
          );
        })}
        {point && (
          <line x1={x(point.t)} x2={x(point.t)} y1={0} y2={height} stroke="var(--w-text-2)" strokeWidth={1}
            vectorEffect="non-scaling-stroke" opacity={0.6} />
        )}
      </svg>
      {/* "Now" dot, drawn outside the stretched SVG so it stays round */}
      <span
        className="absolute w-[7px] h-[7px] rounded-full -translate-x-1/2 -translate-y-1/2 pointer-events-none"
        style={{ left: `${(x(last.t) / width) * 100}%`, top: y(last.v), background: color, boxShadow: '0 0 0 2px var(--w-tile)' }}
        aria-hidden
      />
      {point && (
        <span className="w-bar-tip" style={{ left: `${(x(point.t) / width) * 100}%`, transform: `translateX(-${(x(point.t) / width) * 100}%)` }} aria-hidden>
          <strong className="font-semibold">{format(point.v)}</strong> · {formatWhen(new Date(point.t * 1000))}
        </span>
      )}
    </div>
  );
}

/** Disk usage ring. */
export function Ring({ percent, state, children }: { percent: number | null; state: TileState; children: React.ReactNode }) {
  const r = 52;
  const c = 2 * Math.PI * r;
  const filled = percent == null ? 0 : Math.min(Math.max(percent, 0), 100) / 100;
  const color = state === 'crit' ? 'var(--w-red-fill)' : state === 'warn' ? 'var(--w-amber-fill)' : 'var(--w-green-fill)';
  return (
    <div className="relative w-[136px] h-[136px] shrink-0">
      <svg viewBox="0 0 128 128" className="w-full h-full -rotate-90" aria-hidden>
        <circle cx="64" cy="64" r={r} fill="none" stroke="var(--w-track)" strokeWidth="14" />
        <circle cx="64" cy="64" r={r} fill="none" stroke={color} strokeWidth="14" strokeLinecap="round"
          strokeDasharray={`${c * filled} ${c}`} />
      </svg>
      <div className="absolute inset-0 grid place-items-center">{children}</div>
    </div>
  );
}

/** Files backed up per day; today's bar highlighted. Each bar is focusable and shows its numbers. */
export function DayBars({ days, height = 150 }: { days: BackupDay[]; height?: number }) {
  const max = Math.max(1, ...days.map((d) => d.files));
  // Only the hovered or focused bar renders its tooltip; the rest carry their numbers in aria-label
  const [active, setActive] = useState<number | null>(null);
  return (
    <div>
      <ol className="flex items-end gap-[3px]" style={{ height }} aria-label="Files backed up per day">
        {days.map((day, i) => {
          const today = i === days.length - 1;
          const share = day.files / max;
          const label = `${formatDay(day.date)}: ${formatCount(day.files)} files, ${formatBytes(day.bytes)}`;
          const lit = today || active === i;
          return (
            <li key={day.date} className="w-bar" tabIndex={0} aria-label={label}
              data-align={i < days.length / 3 ? 'start' : i >= (days.length * 2) / 3 ? 'end' : undefined}
              onMouseEnter={() => setActive(i)} onMouseLeave={() => setActive(null)}
              onFocus={() => setActive(i)} onBlur={() => setActive(null)}>
              <span
                className="block w-full rounded-[3px]"
                style={{
                  height: day.files ? `max(3px, ${share * 100}%)` : '2px',
                  background: lit && day.files ? 'var(--w-green-fill)' : day.files ? 'var(--w-green-soft)' : 'var(--w-track)',
                  opacity: active === i && !today ? 0.75 : 1,
                }}
              />
              {active === i && <span className="w-bar-tip" aria-hidden>
                <strong className="font-semibold">{formatDay(day.date)}</strong>
                <br />
                {formatCount(day.files)} files · {formatBytes(day.bytes)}
                {day.files > 0 && (
                  <>
                    <br />
                    {formatCount(day.new_files)} new, {formatCount(day.files - day.new_files)} already on the NAS
                  </>
                )}
              </span>}
            </li>
          );
        })}
      </ol>
      {days.length > 0 && (
        <div className="flex justify-between mt-2 w-caption">
          <span>{formatDay(days[0].date)}</span>
          <span>Today</span>
        </div>
      )}
    </div>
  );
}

/** What the vault holds by kind, as one bar. */
export function StorageBar({ parts }: { parts: { label: string; bytes: number; color: string }[] }) {
  const total = parts.reduce((sum, p) => sum + p.bytes, 0);
  return (
    <div>
      <div className="flex h-3 rounded-full overflow-hidden bg-[var(--w-track)]" aria-hidden>
        {total > 0 && parts.map((p) => (
          <span key={p.label} style={{ width: `${(p.bytes / total) * 100}%`, background: p.color }} />
        ))}
      </div>
      <ul className="flex flex-wrap gap-x-4 gap-y-1 mt-2.5 w-caption">
        {parts.map((p) => (
          <li key={p.label} className="flex items-center gap-1.5">
            <span className="w-2 h-2 rounded-full" style={{ background: p.color }} aria-hidden />
            {p.label} <span className="text-[var(--w-text)]">{formatBytes(p.bytes)}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
