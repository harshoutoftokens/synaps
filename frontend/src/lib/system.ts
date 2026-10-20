/**
 * Stats dashboard data: types and fetchers for /api/system/* (backend/routers/system.py),
 * plus the formatting the dashboard shares. Metric timestamps are UTC unix seconds;
 * datetimes are ISO 8601 UTC strings. A null value means "could not be measured".
 */
'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { fetchAPI } from '@/lib/api';

export interface SystemNow {
  hostname: string;
  sampled_at: number;
  sampler_running: boolean;
  cpu: { percent: number | null; cores: number | null; load: number[] | null };
  memory: { total: number | null; used: number | null; available: number | null; swap_total: number | null; swap_used: number | null };
  temperature_c: number | null;
  network: { rx_bps: number | null; tx_bps: number | null };
  disk: { total: number | null; used: number | null; free: number | null; percent: number | null };
  uptime: { system_seconds: number | null; backend_seconds: number };
  services: { thumbnail_queue: number | null; scan_running: boolean | null; database_bytes: number | null; api_token_enabled: boolean };
}

export interface MetricPoint {
  t: number;
  cpu_percent: number | null;
  load_1: number | null;
  mem_used: number | null;
  mem_total: number | null;
  swap_used: number | null;
  temp_c: number | null;
  net_rx_bps: number | null;
  net_tx_bps: number | null;
  disk_used: number | null;
  disk_total: number | null;
  cpu_max?: number | null;
  temp_max?: number | null;
}

export type HistoryRange = '1h' | '24h' | '7d' | '30d';

export interface SystemHistory {
  range: HistoryRange;
  resolution_seconds: number;
  collecting_since: number | null;
  points: MetricPoint[];
}

export interface BackupDay {
  date: string;
  files: number;
  bytes: number;
  new_files: number;
  new_bytes: number;
  by_device: Record<string, { files: number; bytes: number }>;
}

export interface BackupHistory {
  days: number;
  start: string;
  devices: Record<string, string>;
  series: BackupDay[];
}

export interface Device {
  id: string;
  name: string;
  platform: string;
  files: number;
  bytes: number;
  last_backup_at: string | null;
  last_contact_at: string | null;
  registered_at: string | null;
}

export interface ActivityItem {
  id: string;
  imported_at: string | null;
  device_id: string;
  device_name: string | null;
  filename: string;
  location: string;
  bytes: number;
  mime_type: string | null;
}

export interface ActivityPage {
  items: ActivityItem[];
  next_before: string | null;
}

export interface StorageInfo {
  vault: {
    by_kind: Record<'photos' | 'videos' | 'other', { files: number; bytes: number }>;
    stored_files: number;
    stored_bytes: number;
    uploaded_files: number;
    uploaded_bytes: number;
    dedup_saved_bytes: number;
  };
  thumbnail_cache_bytes: number | null;
  trash_bytes: number | null;
  disk: { total: number; used: number; free: number } | null;
}

export const getSystemNow = (): Promise<SystemNow> => fetchAPI('/system/now', { cache: 'no-store' });
export const getSystemHistory = (range: HistoryRange): Promise<SystemHistory> =>
  fetchAPI(`/system/history?range=${range}`, { cache: 'no-store' });
export const getBackupHistory = (days = 30): Promise<BackupHistory> =>
  fetchAPI(`/system/backups?days=${days}`, { cache: 'no-store' });
export const getDevices = (): Promise<{ devices: Device[] }> => fetchAPI('/system/devices', { cache: 'no-store' });
export const getActivity = (before?: string | null, limit = 25): Promise<ActivityPage> => {
  const params = new URLSearchParams({ limit: String(limit) });
  if (before) params.set('before', before);
  return fetchAPI(`/system/activity?${params}`, { cache: 'no-store' });
};
export const getStorage = (): Promise<StorageInfo> => fetchAPI('/system/storage', { cache: 'no-store' });

// ── Polling ───────────────────────────────────────────────────────────

export interface Polled<T> {
  data: T | null;
  error: Error | null;
  /** When the last successful response arrived (ms since epoch). */
  updatedAt: number | null;
  reload: () => void;
}

/**
 * Fetch now and every `intervalMs` while the tab is visible. A hidden tab stops polling, so a
 * forgotten dashboard doesn't keep the NAS busy, and refreshes as soon as it is shown again.
 * The last good data stays on screen when a request fails.
 */
export function usePolling<T>(fetcher: () => Promise<T>, intervalMs: number, deps: unknown[] = []): Polled<T> {
  const [data, setData] = useState<T | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [updatedAt, setUpdatedAt] = useState<number | null>(null);
  const fetcherRef = useRef(fetcher);
  fetcherRef.current = fetcher;
  const generation = useRef(0);

  const load = useCallback(() => {
    const mine = ++generation.current;
    fetcherRef.current()
      .then((result) => {
        if (mine !== generation.current) return;
        setData(result);
        setError(null);
        setUpdatedAt(Date.now());
      })
      .catch((e) => {
        if (mine === generation.current) setError(e instanceof Error ? e : new Error(String(e)));
      });
  }, []);

  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;
    const start = () => {
      if (timer) return;
      load();
      timer = setInterval(load, intervalMs);
    };
    const stop = () => {
      if (timer) clearInterval(timer);
      timer = null;
    };
    const onVisibility = () => (document.hidden ? stop() : start());
    if (!document.hidden) start();
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      stop();
      document.removeEventListener('visibilitychange', onVisibility);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [load, intervalMs, ...deps]);

  return { data, error, updatedAt, reload: load };
}

// ── Formatting ────────────────────────────────────────────────────────

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

/** Bytes in base 1024, like the rest of the web app (routers/settings.py _fmt). */
export function formatBytes(bytes: number | null | undefined, digits = 1): string {
  if (bytes == null) return '—';
  if (bytes < 1024) return `${bytes} B`;
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value >= 100 ? 0 : digits)} ${UNITS[unit]}`;
}

/** Splits a byte count into its number and unit, for a big figure with a small unit. */
export function bytesParts(bytes: number | null | undefined, digits = 1): [string, string] {
  const [value, unit] = formatBytes(bytes, digits).split(' ');
  return [value, unit ?? ''];
}

export function formatRate(bytesPerSecond: number | null | undefined): string {
  return bytesPerSecond == null ? '—' : `${formatBytes(bytesPerSecond)}/s`;
}

export function formatCount(n: number | null | undefined): string {
  return n == null ? '—' : n.toLocaleString();
}

export function formatDuration(seconds: number | null | undefined): string {
  if (seconds == null) return '—';
  const days = Math.floor(seconds / 86400);
  if (days >= 1) return `${days} ${days === 1 ? 'day' : 'days'}`;
  const hours = Math.floor(seconds / 3600);
  if (hours >= 1) return `${hours} h`;
  return `${Math.max(1, Math.floor(seconds / 60))} min`;
}

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: '2-digit', minute: '2-digit' });
const dayFormat = new Intl.DateTimeFormat(undefined, { day: 'numeric', month: 'short' });

export function parseUtc(iso: string | null | undefined): Date | null {
  return iso ? new Date(iso) : null;
}

export function formatClock(date: Date | number | null | undefined): string {
  if (date == null) return '—';
  return timeFormat.format(typeof date === 'number' ? new Date(date) : date);
}

/** "21:14", "Yesterday 09:30" or "11 Oct" for older dates. */
export function formatWhen(date: Date | null, now = new Date()): string {
  if (!date) return 'Never';
  const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate()).getTime();
  const t = date.getTime();
  if (t >= startOfToday) return timeFormat.format(date);
  if (t >= startOfToday - 86400_000) return `Yesterday ${timeFormat.format(date)}`;
  return dayFormat.format(date);
}

export function daysSince(date: Date | null, now = new Date()): number | null {
  return date ? Math.floor((now.getTime() - date.getTime()) / 86400_000) : null;
}

export function formatDay(isoDate: string): string {
  const [y, m, d] = isoDate.split('-').map(Number);
  return dayFormat.format(new Date(y, m - 1, d));
}

/** A device that hasn't backed up for this many days needs attention. */
export const STALE_DEVICE_DAYS = 7;
