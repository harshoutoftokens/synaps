/**
 * Synaps API Client
 */

const API_BASE = '/api';

export class ApiError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
  }
}

function errorMessage(body: any, fallback: string): string {
  const detail = body?.detail;
  if (typeof detail === 'string') return detail;
  // FastAPI validation errors (422) carry a list of {loc, msg} objects
  if (Array.isArray(detail)) return detail.map((d) => d?.msg ?? String(d)).join('; ');
  return fallback;
}

// ── API token (opt-in server auth) ────────────────────────────────────
// Kept in the `synaps_token` cookie so same-origin <img>/<video> requests carry it too.
// Nothing here runs unless the server answers 401, i.e. it is a no-op when auth is off.

const TOKEN_COOKIE = 'synaps_token';
const TOKEN_MAX_AGE = 60 * 60 * 24 * 365;
// RFC 6265 cookie-octets: no spaces, quotes, commas, semicolons or backslashes
const COOKIE_SAFE = /^[\x21\x23-\x2B\x2D-\x3A\x3C-\x5B\x5D-\x7E]+$/;

export function isValidApiToken(token: string): boolean {
  return COOKIE_SAFE.test(token);
}

export function getApiToken(): string | null {
  if (typeof document === 'undefined') return null;
  for (const part of document.cookie.split(';')) {
    const [name, ...rest] = part.trim().split('=');
    if (name === TOKEN_COOKIE) return rest.join('=') || null;
  }
  return null;
}

export function setApiToken(token: string | null) {
  if (typeof document === 'undefined') return;
  document.cookie = token
    ? `${TOKEN_COOKIE}=${token}; Path=/; Max-Age=${TOKEN_MAX_AGE}; SameSite=Lax`
    : `${TOKEN_COOKIE}=; Path=/; Max-Age=0; SameSite=Lax`;
  clearCache();
}

export interface TokenRequest {
  /** True when a token was sent and the server refused it. */
  rejected: boolean;
  submit: (token: string | null) => void;
}

let tokenListener: ((request: TokenRequest | null) => void) | null = null;
let tokenPrompt: Promise<boolean> | null = null;

/** Lets <TokenPrompt/> render the modal. Returns an unsubscribe function. */
export function subscribeTokenRequests(listener: (request: TokenRequest | null) => void) {
  tokenListener = listener;
  return () => {
    if (tokenListener === listener) tokenListener = null;
  };
}

/** Ask for the token once, however many requests hit 401 at the same time. True if one was stored. */
function promptForToken(rejected: boolean): Promise<boolean> {
  if (tokenPrompt) return tokenPrompt;
  const prompt = new Promise<boolean>((resolve) => {
    const submit = (token: string | null) => {
      tokenListener?.(null);
      const clean = token?.trim() ?? '';
      if (clean && isValidApiToken(clean)) {
        setApiToken(clean);
        resolve(true);
      } else {
        resolve(false);
      }
    };
    if (tokenListener) tokenListener({ rejected, submit });
    else submit(window.prompt('This Synaps server requires an API token:'));
  });
  tokenPrompt = prompt;
  prompt.then(() => {
    if (tokenPrompt === prompt) tokenPrompt = null;
  });
  return prompt;
}

/** True if the 401 should be retried: another request already stored a new token, or the user entered one. */
async function recoverFromUnauthorized(sentToken: string | null): Promise<boolean> {
  if (typeof window === 'undefined') return false;
  if (getApiToken() !== sentToken) return true;
  return promptForToken(sentToken !== null);
}

/** GET/POST with the API token flow (prompts once on 401, then retries). */
export async function fetchAPI(endpoint: string, options?: RequestInit) {
  for (;;) {
    const sentToken = getApiToken();
    const res = await fetch(`${API_BASE}${endpoint}`, options);
    if (res.status === 401 && (await recoverFromUnauthorized(sentToken))) continue;
    if (!res.ok) {
      const body = await res.json().catch(() => null);
      throw new ApiError(res.status, errorMessage(body, res.statusText || `HTTP ${res.status}`));
    }
    return res.json();
  }
}

/** Check whether the stored token (or no token) is accepted, without prompting. */
export async function verifyApiToken(): Promise<'ok' | 'rejected' | 'error'> {
  try {
    const res = await fetch(`${API_BASE}/sync/history?per_page=1`, { cache: 'no-store' });
    if (res.status === 401) return 'rejected';
    return res.ok ? 'ok' : 'error';
  } catch {
    return 'error';
  }
}

/** Cheap authenticated request; triggers the token prompt if the server wants one. */
export async function checkAuth() {
  return fetchAPI('/sync/history?per_page=1');
}

// ── Small GET cache ───────────────────────────────────────────────────
// Dedupes identical requests made by several components (sidebar + library both want stats)
// and avoids re-querying the NAS on every navigation. Mutations call clearCache().

const cache = new Map<string, { at: number; promise: Promise<any> }>();

function cachedGet(endpoint: string, ttlMs: number) {
  const hit = cache.get(endpoint);
  if (hit && Date.now() - hit.at < ttlMs) return hit.promise;
  const promise = fetchAPI(endpoint);
  cache.set(endpoint, { at: Date.now(), promise });
  promise.catch(() => {
    if (cache.get(endpoint)?.promise === promise) cache.delete(endpoint);
  });
  return promise;
}

export function clearCache() {
  cache.clear();
}

// Endpoints are called without a trailing slash: Next.js 308-redirects `/api/x/` to `/api/x`
// before proxying, and FastAPI's own slash redirect then points at http://localhost:8000/...,
// which other LAN devices can't reach. The backend registers the slash-less routes.

// Media / Timeline
export async function getMedia(params: {
  view?: string;
  sources?: string;
  page?: number;
  per_page?: number;
  media_type?: string;
  year?: number;
  month?: number;
}) {
  const searchParams = new URLSearchParams();
  if (params.view) searchParams.set('view', params.view);
  if (params.sources) searchParams.set('sources', params.sources);
  if (params.page) searchParams.set('page', String(params.page));
  if (params.per_page) searchParams.set('per_page', String(params.per_page));
  if (params.media_type) searchParams.set('media_type', params.media_type);
  if (params.year) searchParams.set('year', String(params.year));
  if (params.month) searchParams.set('month', String(params.month));
  return fetchAPI(`/media?${searchParams.toString()}`);
}

export async function getMediaItem(id: string) {
  return fetchAPI(`/media/item/${id}`);
}

export async function getMediaStats() {
  return cachedGet('/media/stats', 60_000);
}

export async function toggleFavorite(id: string) {
  return fetchAPI(`/media/favorite/${id}`, { method: 'POST' });
}

export function getThumbnailUrl(id: string) {
  return `${API_BASE}/media/thumbnail/${id}`;
}

export function getFileUrl(id: string) {
  // Cache-bust to avoid stale 500 responses from previous backend versions
  return `${API_BASE}/media/file/${id}?_v=2`;
}

export function getStreamUrl(id: string) {
  return `${API_BASE}/media/stream/${id}`;
}

// Finder
export async function browseDirectory(path: string = '', page: number = 1, perPage: number = 200) {
  const params = new URLSearchParams({ path, page: String(page), per_page: String(perPage) });
  return fetchAPI(`/finder/browse?${params.toString()}`);
}

/** Original file bytes by storage-relative path (also what media items' `path` field holds). */
export function getFinderFileUrl(path: string) {
  return `${API_BASE}/finder/download?path=${encodeURIComponent(path)}`;
}

export async function getDirectoryTree(depth: number = 2) {
  return fetchAPI(`/finder/tree?depth=${depth}`);
}

// Search
export async function searchMedia(query: string, mediaType?: string, page: number = 1) {
  const params = new URLSearchParams({ q: query, page: String(page) });
  if (mediaType) params.set('media_type', mediaType);
  return fetchAPI(`/search?${params.toString()}`);
}

export async function getSearchSuggestions(query: string) {
  return fetchAPI(`/search/suggestions?q=${encodeURIComponent(query)}`);
}

// Sync
// Under `next start` (port 3000) /api/* goes through Next's rewrite proxy, which buffers the whole
// request body in Node memory (a 600 MB upload grew next-server RSS by ~520 MB in testing). On the
// 2 GB NAS that can take the box down, so uploads go straight to the FastAPI port instead. When the
// static export is served by the backend itself, /api is already direct and same-origin.
const PROXY_UPLOAD_LIMIT = 64 * 1024 * 1024;
let directUploadUnavailable = false;

function directApiOrigin(): string | null {
  if (typeof window === 'undefined') return null;
  const override = process.env.NEXT_PUBLIC_SYNAPS_DIRECT_API;
  if (override !== undefined) return override || null;
  const { protocol, hostname, port } = window.location;
  return port === '3000' ? `${protocol}//${hostname}:8000` : null;
}

class UploadNetworkError extends Error {}

export interface UploadResult {
  status: string;
  message?: string;
  filename?: string;
}

export interface UploadOptions {
  device?: string;
  signal?: AbortSignal;
  onProgress?: (loaded: number, total: number) => void;
  /** Body fully sent; the server is hashing/storing it now. */
  onSent?: () => void;
}

function xhrUpload(origin: string, file: File, opts: UploadOptions): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    if (opts.signal?.aborted) {
      reject(new DOMException('Upload cancelled', 'AbortError'));
      return;
    }
    const xhr = new XMLHttpRequest();
    xhr.open('POST', `${origin}${API_BASE}/sync/upload`);
    // Different port = different origin, but the same site: this sends the synaps_token cookie
    if (origin) xhr.withCredentials = true;
    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) opts.onProgress?.(e.loaded, e.total);
    };
    xhr.upload.onload = () => opts.onSent?.();
    xhr.onload = () => {
      let body: any = null;
      try {
        body = JSON.parse(xhr.responseText);
      } catch {}
      resolve({ status: xhr.status, body });
    };
    xhr.onerror = () => reject(new UploadNetworkError('Network error during upload'));
    xhr.onabort = () => reject(new DOMException('Upload cancelled', 'AbortError'));
    opts.signal?.addEventListener('abort', () => xhr.abort(), { once: true });

    const formData = new FormData();
    formData.append('file', file);
    formData.append('device', opts.device ?? 'iPhone');
    xhr.send(formData);
  });
}

// Same origin + credentials mode as the upload itself, so a CORS setup that would reject the
// upload also fails here and we fall back instead of failing every file
async function backendReachable(origin: string) {
  try {
    const res = await fetch(`${origin}${API_BASE}/health`, { credentials: 'include', signal: AbortSignal.timeout(5000) });
    return res.ok;
  } catch {
    return false;
  }
}

export async function uploadFile(file: File, options: UploadOptions = {}): Promise<UploadResult> {
  for (;;) {
    const direct = directApiOrigin();
    const useDirect = direct !== null && !directUploadUnavailable;
    if (direct !== null && !useDirect && file.size > PROXY_UPLOAD_LIMIT) {
      throw new ApiError(0, `Backend not reachable at ${direct}; files over 64 MB are not sent through the Next.js proxy`);
    }
    const sentToken = getApiToken();
    let result: { status: number; body: any };
    try {
      result = await xhrUpload(useDirect ? direct : '', file, options);
    } catch (err) {
      // Port 8000 blocked/unreachable (or CORS refused): fall back to the same-origin proxy
      if (useDirect && err instanceof UploadNetworkError && !(await backendReachable(direct))) {
        directUploadUnavailable = true;
        continue;
      }
      throw err;
    }
    if (result.status === 401 && (await recoverFromUnauthorized(sentToken))) continue;
    if (result.status < 200 || result.status >= 300) {
      throw new ApiError(result.status, errorMessage(result.body, `Upload failed (HTTP ${result.status})`));
    }
    clearCache();
    return result.body ?? { status: 'success' };
  }
}

export async function getSyncHistory() {
  return fetchAPI('/sync/history');
}

// Trash
export async function getTrash() {
  return fetchAPI('/trash');
}

export async function moveToTrash(mediaId: string) {
  const result = await fetchAPI(`/trash/delete/${mediaId}`, { method: 'POST' });
  clearCache();
  return result;
}

export async function restoreFromTrash(trashId: string) {
  const result = await fetchAPI(`/trash/restore/${trashId}`, { method: 'POST' });
  clearCache();
  return result;
}

export async function permanentDelete(trashId: string) {
  return fetchAPI(`/trash/permanent/${trashId}`, { method: 'DELETE' });
}

// Settings
export async function getSettings() {
  return fetchAPI('/settings');
}

export async function updateSettings(data: Record<string, string>) {
  return fetchAPI('/settings', {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data),
  });
}

export async function getStorageUsage() {
  return fetchAPI('/settings/storage-usage');
}

// Import Manager
export interface ImportScanResult {
  total_files: number;
  photos: number;
  videos: number;
  total_size: number;
  total_size_human: string;
  source_dir: string;
}

export interface ImportPreviewResult {
  destinations: { path: string; count: number }[];
  total_files: number;
  unknown_date: number;
}

export interface ImportProgress {
  job_id: string;
  // 'running' is only used by preview jobs
  status: 'pending' | 'running' | 'scanning' | 'importing' | 'indexing' | 'complete' | 'error' | 'none';
  phase: string;
  progress: number;
  total_files: number;
  processed_files: number;
  imported: number;
  duplicates_skipped: number;
  unknown_date: number;
  errors: number;
  error_log: string[];
  preview_destinations?: ImportPreviewResult | null;
  started_at: string | null;
  completed_at: string | null;
}

export async function scanImports(): Promise<ImportScanResult> {
  return fetchAPI('/import/scan', { method: 'POST' });
}

export async function previewImports(): Promise<{ status: string; job_id: string }> {
  return fetchAPI('/import/preview', { method: 'POST' });
}

export async function executeImport(): Promise<{ status: string; job_id: string }> {
  return fetchAPI('/import/execute', { method: 'POST' });
}

export async function getImportProgress(jobId: string): Promise<ImportProgress> {
  return fetchAPI(`/import/progress/${jobId}`);
}

export async function getLatestImport(): Promise<ImportProgress> {
  return fetchAPI('/import/latest');
}

// Health
export async function checkHealth() {
  return fetchAPI('/health');
}

// Trigger scan
export async function triggerScan() {
  const result = await fetchAPI('/scan', { method: 'POST' });
  clearCache();
  return result;
}
