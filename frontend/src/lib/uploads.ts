import { create } from 'zustand';
import { ApiError, checkAuth, uploadFile } from '@/lib/api';

export type UploadStatus = 'pending' | 'uploading' | 'processing' | 'success' | 'duplicate' | 'error' | 'cancelled';

export interface UploadItem {
  id: number;
  file: File;
  status: UploadStatus;
  /** Percent of the file's bytes sent (0–100). */
  progress: number;
  message?: string;
}

interface UploadState {
  items: UploadItem[];
  running: boolean;
  addFiles: (files: File[]) => void;
  start: () => Promise<void>;
  cancelAll: () => void;
  retryFailed: () => void;
  clearFinished: () => void;
}

// Two parallel uploads keep the LAN busy without swamping the NAS. Big files take both slots:
// the legacy /api/sync/upload endpoint reads the whole file into the backend's RAM.
const MAX_SLOTS = 2;
const BIG_FILE_BYTES = 256 * 1024 * 1024;
const FINISHED: UploadStatus[] = ['success', 'duplicate', 'error', 'cancelled'];

let nextId = 1;
let busySlots = 0;
const controllers = new Map<number, AbortController>();

export const useUploads = create<UploadState>((set, get) => {
  const patch = (id: number, changes: Partial<UploadItem>) =>
    set((s) => ({ items: s.items.map((u) => (u.id === id ? { ...u, ...changes } : u)) }));

  const run = async (item: UploadItem, weight: number) => {
    const controller = new AbortController();
    controllers.set(item.id, controller);
    patch(item.id, { status: 'uploading', progress: 0, message: undefined });
    let lastPercent = -1;
    try {
      const result = await uploadFile(item.file, {
        signal: controller.signal,
        onProgress: (loaded, total) => {
          // Progress events fire many times a second; only re-render on whole-percent changes
          const percent = total > 0 ? Math.floor((loaded / total) * 100) : 0;
          if (percent !== lastPercent) {
            lastPercent = percent;
            patch(item.id, { status: 'uploading', progress: percent });
          }
        },
        onSent: () => patch(item.id, { status: 'processing', progress: 100 }),
      });
      patch(item.id, {
        status: result.status === 'duplicate' ? 'duplicate' : 'success',
        progress: 100,
        message: result.message,
      });
    } catch (err: any) {
      if (err?.name === 'AbortError') patch(item.id, { status: 'cancelled', progress: 0, message: 'Cancelled' });
      else patch(item.id, { status: 'error', progress: 0, message: err?.message || 'Upload failed' });
    } finally {
      controllers.delete(item.id);
      busySlots -= weight;
      pump();
    }
  };

  // Start pending uploads in order while slots are free
  const pump = () => {
    if (!get().running) return;
    for (const item of get().items) {
      if (item.status !== 'pending' || controllers.has(item.id)) continue;
      const weight = item.file.size >= BIG_FILE_BYTES ? MAX_SLOTS : 1;
      if (busySlots + weight > MAX_SLOTS) break;
      busySlots += weight;
      run(item, weight);
    }
    if (busySlots === 0 && !get().items.some((u) => u.status === 'pending')) set({ running: false });
  };

  return {
    items: [],
    running: false,

    addFiles: (files) => {
      const added = files.map((file) => ({ id: nextId++, file, status: 'pending' as const, progress: 0 }));
      set((s) => ({ items: [...s.items, ...added] }));
      pump(); // joins a batch that's already running
    },

    start: async () => {
      if (get().running || !get().items.some((u) => u.status === 'pending')) return;
      set({ running: true });
      try {
        // Ask for the API token (if the server wants one) once, before any bytes are sent
        await checkAuth();
      } catch (err) {
        if (err instanceof ApiError && err.status === 401) {
          set((s) => ({
            running: false,
            items: s.items.map((u) => (u.status === 'pending' ? { ...u, status: 'error', message: 'API token required' } : u)),
          }));
          return;
        }
        // Anything else (e.g. server unreachable) will be reported per file
      }
      pump();
    },

    cancelAll: () => {
      set((s) => ({
        running: false,
        items: s.items.map((u) => (u.status === 'pending' ? { ...u, status: 'cancelled', message: 'Cancelled' } : u)),
      }));
      controllers.forEach((c) => c.abort());
    },

    retryFailed: () =>
      set((s) => ({
        items: s.items.map((u) =>
          u.status === 'error' || u.status === 'cancelled' ? { ...u, status: 'pending', progress: 0, message: undefined } : u
        ),
      })),

    clearFinished: () => set((s) => ({ items: s.items.filter((u) => !FINISHED.includes(u.status)) })),
  };
});

// Closing or reloading the tab kills in-flight uploads; ask first
if (typeof window !== 'undefined') {
  const warnBeforeUnload = (e: BeforeUnloadEvent) => {
    e.preventDefault();
    e.returnValue = '';
  };
  let warning = false;
  useUploads.subscribe((state) => {
    const active = state.running || state.items.some((u) => u.status === 'uploading' || u.status === 'processing');
    if (active === warning) return;
    warning = active;
    if (active) window.addEventListener('beforeunload', warnBeforeUnload);
    else window.removeEventListener('beforeunload', warnBeforeUnload);
  });
}
