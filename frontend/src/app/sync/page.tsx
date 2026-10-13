'use client';

import { useState, useRef, useEffect, memo } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TopBar } from '@/components/TopBar';
import { GlassPanel } from '@/components/glass/GlassPanel';
import { GlassButton } from '@/components/glass/GlassButton';
import { useUploads, type UploadItem } from '@/lib/uploads';
import {
  clearCache,
  scanImports,
  previewImports,
  executeImport,
  getImportProgress,
  getLatestImport,
  ImportScanResult,
  ImportPreviewResult,
  ImportProgress,
} from '@/lib/api';
import {
  Upload, Smartphone, CheckCircle2, XCircle, Clock,
  Loader2, CloudUpload, Image as ImageIcon, Film,
  Package, FolderInput, Scan, ArrowRight, AlertTriangle,
  HardDrive, Camera, Video, FolderOpen, FileQuestion,
} from 'lucide-react';

// ── Types ─────────────────────────────────────────────────────────────

type ImportState =
  | 'idle'
  | 'scanning'
  | 'scanned'
  | 'previewing'
  | 'previewed'
  | 'importing'
  | 'complete'
  | 'error';

// ── Import Section Component ──────────────────────────────────────────

function ImportSection() {
  const [importState, setImportState] = useState<ImportState>('idle');
  const [scanResult, setScanResult] = useState<ImportScanResult | null>(null);
  const [previewResult, setPreviewResult] = useState<ImportPreviewResult | null>(null);
  const [progress, setProgress] = useState<ImportProgress | null>(null);
  const [jobId, setJobId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const pollRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pollIdRef = useRef(0);

  // Check for existing running job on mount
  useEffect(() => {
    const checkLatest = async () => {
      try {
        const latest = await getLatestImport();
        if (!latest || latest.status === 'none') return;
        // Preview jobs share the job list with imports ('running' is preview-only)
        const isPreviewJob = latest.status === 'running' || latest.preview_destinations != null;
        if (isPreviewJob) {
          if (latest.status === 'running') {
            setJobId(latest.job_id);
            setProgress(latest);
            setImportState('previewing');
            startPolling(latest.job_id, true);
          }
          // A finished preview isn't an import: stay idle instead of showing "Import Complete"
        } else if (['scanning', 'importing', 'indexing', 'pending'].includes(latest.status)) {
          setJobId(latest.job_id);
          setProgress(latest);
          setImportState('importing');
          startPolling(latest.job_id);
        } else if (latest.status === 'complete') {
          setProgress(latest);
          setImportState('complete');
        }
      } catch {
        // No previous job, stay idle
      }
    };
    checkLatest();
    return () => stopPolling();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const stopPolling = () => {
    pollIdRef.current++;
    if (pollRef.current) {
      clearTimeout(pollRef.current);
      pollRef.current = null;
    }
  };

  // Chained timeouts rather than setInterval: on a busy NAS a poll can take longer than the
  // interval, and overlapping polls just pile more load on it.
  const startPolling = (id: string, isPreview: boolean = false) => {
    stopPolling();
    const pollId = pollIdRef.current;
    const poll = async () => {
      try {
        const p = await getImportProgress(id);
        if (pollId !== pollIdRef.current) return;
        setProgress(p);
        if (p.status === 'complete') {
          stopPolling();
          if (isPreview && p.preview_destinations) {
            setPreviewResult(p.preview_destinations);
            setImportState('previewed');
          } else if (!isPreview) {
            clearCache();
            setImportState('complete');
          }
          return;
        }
        if (p.status === 'error') {
          stopPolling();
          setImportState('error');
          setError(p.error_log?.[p.error_log.length - 1] || p.phase || 'Unknown error');
          return;
        }
      } catch {
        // Keep polling, might be a transient error
      }
      if (pollId === pollIdRef.current) pollRef.current = setTimeout(poll, 2000);
    };
    pollRef.current = setTimeout(poll, 2000);
  };

  const handleScan = async () => {
    setImportState('scanning');
    setError(null);
    try {
      const result = await scanImports();
      setScanResult(result);
      setImportState(result.total_files > 0 ? 'scanned' : 'idle');
      if (result.total_files === 0) {
        setError('No files found in import folder');
      }
    } catch (err: any) {
      setImportState('error');
      setError(err.message || 'Scan failed');
    }
  };

  const handlePreview = async () => {
    setImportState('previewing');
    setError(null);
    try {
      const result: any = await previewImports();
      if (result.status === 'started' && result.job_id) {
        setJobId(result.job_id);
        startPolling(result.job_id, true);
      } else if (result.destinations) {
        // Older backends answered synchronously with the preview itself
        setPreviewResult(result);
        setImportState('previewed');
      } else {
        throw new Error('Unexpected preview response');
      }
    } catch (err: any) {
      setImportState('error');
      setError(err.message || 'Preview failed');
    }
  };

  const handleExecute = async () => {
    setError(null);
    try {
      const result = await executeImport();
      setJobId(result.job_id);
      setImportState('importing');
      startPolling(result.job_id);
    } catch (err: any) {
      setImportState('error');
      setError(err.message || 'Import failed to start');
    }
  };

  const handleReset = () => {
    stopPolling();
    setImportState('idle');
    setScanResult(null);
    setPreviewResult(null);
    setProgress(null);
    setJobId(null);
    setError(null);
  };

  const folderIcon = (path: string) => {
    if (path.startsWith('Timeline/')) return <FolderOpen size={15} className="text-[var(--accent)]" />;
    if (path === 'Old_Photos') return <Camera size={15} className="text-amber-400" />;
    if (path === 'Unknown_Date') return <FileQuestion size={15} className="text-[var(--text-tertiary)]" />;
    return <FolderOpen size={15} className="text-[var(--text-tertiary)]" />;
  };

  return (
    <GlassPanel
      as={motion.div as any}
      variant="card"
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.1 }}
    >
      {/* Header */}
      <div className="flex items-center gap-3 mb-5">
        <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-emerald-500 to-teal-600 flex items-center justify-center shadow-lg shadow-emerald-500/20">
          <Package size={20} className="text-white" />
        </div>
        <div>
          <h2 className="text-[14px] font-semibold text-[var(--text-primary)]">
            Imports
          </h2>
          <p className="text-[11px] text-[var(--text-tertiary)]">
            Organize media from import folder
          </p>
        </div>
      </div>

      <AnimatePresence mode="wait">
        {/* ── IDLE STATE ── */}
        {importState === 'idle' && (
          <motion.div key="idle" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
            <p className="text-[13px] text-[var(--text-secondary)] mb-5 leading-relaxed">
              Scan your import folder to find new media waiting to be organized into your library.
            </p>

            {error && (
              <div className="flex items-center gap-2 mb-4 px-3 py-2.5 rounded-xl bg-amber-500/10 border border-amber-500/15">
                <AlertTriangle size={14} className="text-amber-400 shrink-0" />
                <p className="text-[11px] text-amber-400/80">{error}</p>
              </div>
            )}

            <GlassButton variant="accent" onClick={handleScan} className="w-full justify-center py-3" style={{ background: 'linear-gradient(135deg, #10b981, #0d9488)' }}>
              <Scan size={16} />
              Scan Imports
            </GlassButton>
          </motion.div>
        )}

        {/* ── SCANNING STATE ── */}
        {importState === 'scanning' && (
          <motion.div key="scanning" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="flex flex-col items-center py-6">
            <Loader2 size={28} className="text-emerald-400 animate-spin mb-3" />
            <p className="text-[13px] text-[var(--text-tertiary)]">Scanning import folder...</p>
          </motion.div>
        )}

        {/* ── SCANNED STATE ── */}
        {importState === 'scanned' && scanResult && (
          <motion.div key="scanned" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}>
            <div className="grid grid-cols-3 gap-3 mb-5">
              <div className="rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)] p-3 text-center">
                <p className="text-xl font-bold text-[var(--text-primary)]">{scanResult.total_files}</p>
                <p className="text-[10px] uppercase tracking-wider text-[var(--text-tertiary)] mt-0.5">files waiting</p>
              </div>
              <div className="rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)] p-3 text-center">
                <div className="flex items-center justify-center gap-1.5 mb-0.5">
                  <Camera size={13} className="text-blue-400" />
                  <span className="text-xl font-bold text-[var(--text-primary)]">{scanResult.photos}</span>
                </div>
                <p className="text-[10px] uppercase tracking-wider text-[var(--text-tertiary)]">photos</p>
              </div>
              <div className="rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)] p-3 text-center">
                <div className="flex items-center justify-center gap-1.5 mb-0.5">
                  <Video size={13} className="text-purple-400" />
                  <span className="text-xl font-bold text-[var(--text-primary)]">{scanResult.videos}</span>
                </div>
                <p className="text-[10px] uppercase tracking-wider text-[var(--text-tertiary)]">videos</p>
              </div>
            </div>

            <div className="flex items-center gap-2 mb-5 px-3 py-2 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
              <HardDrive size={14} className="text-[var(--text-tertiary)]" />
              <span className="text-[13px] font-medium text-[var(--text-secondary)]">{scanResult.total_size_human}</span>
              <span className="text-[11px] text-[var(--text-tertiary)]">total size</span>
            </div>

            <GlassButton variant="accent" onClick={handlePreview} className="w-full justify-center py-3" style={{ background: 'linear-gradient(135deg, #10b981, #0d9488)' }}>
              <FolderInput size={16} />
              Preview Import
            </GlassButton>
          </motion.div>
        )}

        {/* ── PREVIEWING STATE ── */}
        {importState === 'previewing' && (
          <motion.div key="previewing" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="flex flex-col items-center py-6">
            <Loader2 size={28} className="text-emerald-400 animate-spin mb-3" />
            <p className="text-[13px] text-[var(--text-tertiary)]">Extracting metadata & computing destinations...</p>
            <p className="text-[11px] text-[var(--text-muted)] mt-1">This may take a moment for large libraries</p>
            {progress && (
              <div className="w-full mt-4">
                <div className="flex justify-between text-[10px] text-[var(--text-tertiary)] mb-1">
                  <span>{progress.phase}</span>
                  <span>{progress.progress}%</span>
                </div>
                <div className="h-1 bg-[var(--glass-bg-hover)] rounded-full overflow-hidden">
                  <motion.div className="h-full bg-emerald-500 rounded-full" animate={{ width: `${progress.progress}%` }} />
                </div>
              </div>
            )}
          </motion.div>
        )}

        {/* ── PREVIEWED STATE ── */}
        {importState === 'previewed' && previewResult && (
          <motion.div key="previewed" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}>
            <h3 className="text-[13px] font-semibold text-[var(--text-primary)] mb-3">Import Preview</h3>

            <div className="space-y-1 mb-5">
              {previewResult.destinations.map((dest, i) => (
                <motion.div
                  key={dest.path}
                  initial={{ opacity: 0, x: -10 }}
                  animate={{ opacity: 1, x: 0 }}
                  transition={{ delay: i * 0.03 }}
                  className="flex items-center justify-between px-3 py-2.5 rounded-xl
                    bg-[var(--glass-bg)] border border-[var(--glass-border)]"
                >
                  <div className="flex items-center gap-2.5">
                    {folderIcon(dest.path)}
                    <span className="text-[11px] font-medium text-[var(--text-secondary)] font-mono">{dest.path}</span>
                  </div>
                  <div className="flex items-center gap-1.5">
                    <ArrowRight size={12} className="text-[var(--text-muted)]" />
                    <span className="text-[12px] font-semibold text-[var(--text-primary)] tabular-nums">{dest.count}</span>
                    <span className="text-[10px] text-[var(--text-tertiary)]">{dest.count === 1 ? 'file' : 'files'}</span>
                  </div>
                </motion.div>
              ))}
            </div>

            <div className="flex gap-2">
              <button onClick={handleReset} className="flex-1 px-4 py-3 rounded-xl text-[13px] font-medium text-[var(--text-secondary)] bg-[var(--glass-bg)] hover:bg-[var(--glass-bg-hover)] transition-all border border-[var(--glass-border)]">
                Cancel
              </button>
              <GlassButton variant="accent" onClick={handleExecute} className="flex-[2] justify-center py-3" style={{ background: 'linear-gradient(135deg, #10b981, #0d9488)' }}>
                <FolderInput size={16} />
                Start Import
              </GlassButton>
            </div>
          </motion.div>
        )}

        {/* ── IMPORTING STATE ── */}
        {importState === 'importing' && progress && (
          <motion.div key="importing" initial={{ opacity: 0, y: 10 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0 }}>
            <div className="mb-5">
              <div className="flex items-center justify-between mb-2">
                <div className="flex items-center gap-2">
                  <Loader2 size={14} className="text-emerald-400 animate-spin" />
                  <span className="text-[13px] font-medium text-[var(--text-secondary)]">{progress.phase}</span>
                </div>
                <span className="text-[13px] font-bold text-emerald-400 tabular-nums">{progress.progress}%</span>
              </div>
              <div className="h-2 rounded-full bg-[var(--glass-bg)] overflow-hidden border border-[var(--glass-border)]">
                <motion.div
                  className="h-full rounded-full bg-gradient-to-r from-emerald-500 to-teal-500"
                  initial={{ width: 0 }}
                  animate={{ width: `${progress.progress}%` }}
                  transition={{ duration: 0.5, ease: 'easeOut' }}
                />
              </div>
              {progress.total_files > 0 && (
                <p className="text-[11px] text-[var(--text-tertiary)] mt-2 tabular-nums">
                  {progress.processed_files} / {progress.total_files} processed
                </p>
              )}
            </div>
            <div className="grid grid-cols-2 gap-2 text-xs">
              <div className="px-3 py-2 rounded-lg bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                <span className="text-[var(--text-tertiary)]">Imported </span>
                <span className="font-semibold text-emerald-400 tabular-nums">{progress.imported}</span>
              </div>
              <div className="px-3 py-2 rounded-lg bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                <span className="text-[var(--text-tertiary)]">Skipped </span>
                <span className="font-semibold text-amber-400 tabular-nums">{progress.duplicates_skipped}</span>
              </div>
            </div>
          </motion.div>
        )}

        {/* ── COMPLETE STATE ── */}
        {importState === 'complete' && progress && (
          <motion.div key="complete" initial={{ opacity: 0, scale: 0.95 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0 }}>
            <div className="flex items-center gap-2 mb-4">
              <div className="w-8 h-8 rounded-full bg-emerald-500/15 flex items-center justify-center">
                <CheckCircle2 size={18} className="text-emerald-400" />
              </div>
              <h3 className="text-[13px] font-semibold text-[var(--text-primary)]">Import Complete</h3>
            </div>

            <div className="space-y-1.5 mb-5">
              {[
                { label: 'Imported', value: progress.imported, color: 'text-emerald-400' },
                { label: 'Duplicates Skipped', value: progress.duplicates_skipped, color: 'text-amber-400' },
                { label: 'Unknown Date', value: progress.unknown_date, color: 'text-[var(--text-tertiary)]' },
                { label: 'Errors', value: progress.errors, color: progress.errors > 0 ? 'text-red-400' : 'text-[var(--text-tertiary)]' },
              ].map((stat) => (
                <div key={stat.label} className="flex items-center justify-between px-3 py-2 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                  <span className="text-[11px] text-[var(--text-tertiary)]">{stat.label}</span>
                  <span className={`text-[13px] font-semibold tabular-nums ${stat.color}`}>{stat.value}</span>
                </div>
              ))}
            </div>

            {progress.error_log && progress.error_log.length > 0 && (
              <div className="mb-5 px-3 py-2 rounded-xl bg-[var(--glass-bg)] max-h-40 overflow-y-auto border border-[var(--glass-border)]">
                <p className="text-[10px] font-semibold text-[var(--text-tertiary)] mb-2 uppercase tracking-wider">Import Log</p>
                <div className="space-y-1">
                  {progress.error_log.map((log, i) => (
                    <p key={i} className="text-[10px] text-[var(--text-tertiary)] font-mono leading-relaxed">{log}</p>
                  ))}
                </div>
              </div>
            )}

            <p className="text-[11px] text-[var(--text-tertiary)] text-center mb-4">
              New media is now visible in your Timeline
            </p>

            <button onClick={handleReset} className="w-full px-4 py-3 rounded-xl text-[13px] font-medium text-[var(--text-secondary)] bg-[var(--glass-bg)] hover:bg-[var(--glass-bg-hover)] transition-all border border-[var(--glass-border)]">
              Done
            </button>
          </motion.div>
        )}

        {/* ── ERROR STATE ── */}
        {importState === 'error' && (
          <motion.div key="error" initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }}>
            <div className="flex items-center gap-2 mb-4 px-3 py-3 rounded-xl bg-red-500/10 border border-red-500/15">
              <XCircle size={16} className="text-red-400 shrink-0" />
              <div>
                <p className="text-[11px] font-medium text-red-400">Import Error</p>
                <p className="text-[10px] text-red-400/60 mt-0.5">{error}</p>
              </div>
            </div>

            {progress && progress.errors > 0 && progress.error_log.length > 0 && (
              <div className="mb-4 px-3 py-2 rounded-xl bg-[var(--glass-bg)] max-h-32 overflow-y-auto border border-[var(--glass-border)]">
                {progress.error_log.map((log, i) => (
                  <p key={i} className="text-[10px] text-[var(--text-tertiary)] font-mono py-0.5">{log}</p>
                ))}
              </div>
            )}

            <button onClick={handleReset} className="w-full px-4 py-3 rounded-xl text-[13px] font-medium text-[var(--text-secondary)] bg-[var(--glass-bg)] hover:bg-[var(--glass-bg-hover)] transition-all border border-[var(--glass-border)]">
              Try Again
            </button>
          </motion.div>
        )}
      </AnimatePresence>
    </GlassPanel>
  );
}

// ── Upload queue row ──────────────────────────────────────────────────

function formatBytes(bytes: number) {
  if (bytes < 1024 * 1024) return `${Math.max(1, Math.round(bytes / 1024))} KB`;
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

// Memoized: progress updates for one file shouldn't re-render the whole list
const UploadRow = memo(function UploadRow({ item }: { item: UploadItem }) {
  const active = item.status === 'uploading' || item.status === 'processing';
  return (
    <div
      className="flex items-center gap-3 px-3 py-2.5 rounded-xl
        bg-[var(--glass-bg)] border border-[var(--glass-border)]"
    >
      {item.file.type.startsWith('video') ? (
        <Film size={16} className="text-purple-400 shrink-0" />
      ) : (
        <ImageIcon size={16} className="text-blue-400 shrink-0" />
      )}
      <div className="flex-1 min-w-0">
        <div className="flex items-baseline gap-2">
          <p className="text-[11px] text-[var(--text-primary)] truncate">{item.file.name}</p>
          <span className="text-[10px] text-[var(--text-tertiary)] shrink-0 tabular-nums">
            {formatBytes(item.file.size)}
            {item.status === 'uploading' && ` · ${item.progress}%`}
            {item.status === 'processing' && ' · saving on NAS…'}
          </span>
        </div>
        {active && (
          <div
            className="mt-1 h-1 rounded-full bg-[var(--glass-bg-hover)] overflow-hidden"
            role="progressbar"
            aria-valuenow={item.progress}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-label={`Uploading ${item.file.name}`}
          >
            <div className="upload-progress h-full" style={{ width: `${item.progress}%` }} />
          </div>
        )}
        {item.message && (
          <p className={`text-[10px] mt-0.5 ${item.status === 'error' ? 'text-red-400' : 'text-[var(--text-tertiary)]'}`}>
            {item.message}
          </p>
        )}
      </div>
      <div className="shrink-0">
        {item.status === 'pending' && <Clock size={14} className="text-[var(--text-muted)]" />}
        {active && <Loader2 size={14} className="text-[var(--accent)] animate-spin" />}
        {item.status === 'success' && <CheckCircle2 size={14} className="text-emerald-400" />}
        {item.status === 'duplicate' && <CheckCircle2 size={14} className="text-amber-400" />}
        {(item.status === 'error' || item.status === 'cancelled') && <XCircle size={14} className="text-red-400" />}
      </div>
    </div>
  );
});

// ── Main Sync Page ────────────────────────────────────────────────────

export default function SyncPage() {
  // Queue lives in a store so uploads keep going (and stay visible) across page navigation
  const uploads = useUploads((s) => s.items);
  const isUploading = useUploads((s) => s.running);
  const addFiles = useUploads((s) => s.addFiles);
  const startUpload = useUploads((s) => s.start);
  const cancelAll = useUploads((s) => s.cancelAll);
  const retryFailed = useUploads((s) => s.retryFailed);
  const clearFinished = useUploads((s) => s.clearFinished);
  const fileInputRef = useRef<HTMLInputElement>(null);

  const handleFiles = (files: FileList | null) => {
    if (!files || files.length === 0) return;
    addFiles(Array.from(files));
    // Allow picking the same files again later
    if (fileInputRef.current) fileInputRef.current.value = '';
  };

  const stats = { total: uploads.length, success: 0, duplicate: 0, error: 0, pending: 0, active: 0 };
  for (const u of uploads) {
    if (u.status === 'success') stats.success++;
    else if (u.status === 'duplicate') stats.duplicate++;
    else if (u.status === 'error' || u.status === 'cancelled') stats.error++;
    else if (u.status === 'pending') stats.pending++;
    else stats.active++;
  }
  const finished = stats.success + stats.duplicate + stats.error;

  return (
    <div className="min-h-screen">
      <TopBar title="Sync" subtitle="Upload & Import Media" />

      <div className="px-4 lg:px-6 py-6 max-w-2xl mx-auto space-y-5">
        {/* ── Import Manager Section ── */}
        <ImportSection />

        {/* ── iPhone Sync Section ── */}
        <GlassPanel
          as={motion.div as any}
          variant="card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
        >
          <div className="flex items-center gap-3 mb-4">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[var(--accent)] to-[var(--accent-dark)] flex items-center justify-center shadow-lg shadow-[var(--accent-glow)]">
              <Smartphone size={20} className="text-white" />
            </div>
            <div>
              <h2 className="text-[14px] font-semibold text-[var(--text-primary)]">iPhone Sync</h2>
              <p className="text-[11px] text-[var(--text-tertiary)]">Upload photos & videos to your NAS</p>
            </div>
          </div>
          <p className="text-[13px] text-[var(--text-secondary)] mb-5 leading-relaxed">
            Select photos and videos from your iPhone. Files are filed into year/month folders
            and deduplicated: files already on the NAS are skipped.
          </p>

          {/* Upload area */}
          <div
            role="button"
            tabIndex={0}
            onClick={() => fileInputRef.current?.click()}
            onKeyDown={(e) => {
              if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                fileInputRef.current?.click();
              }
            }}
            className="relative border border-dashed border-[var(--accent)]/25 rounded-2xl p-8
              flex flex-col items-center justify-center cursor-pointer
              hover:border-[var(--accent)]/40 hover:bg-[var(--accent-muted)] transition-all duration-200"
          >
            <CloudUpload size={28} className="text-[var(--accent)] mb-3" />
            <p className="text-[13px] font-medium text-[var(--text-secondary)]">Tap to select files</p>
            <p className="text-[11px] text-[var(--text-tertiary)] mt-1">JPEG, PNG, HEIC photos and MP4, MOV videos</p>
            <input
              ref={fileInputRef}
              type="file"
              multiple
              accept="image/*,video/*,.heic,.heif"
              className="hidden"
              onChange={(e) => handleFiles(e.target.files)}
            />
          </div>
        </GlassPanel>

        {/* Upload queue */}
        {uploads.length > 0 && (
          <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }}>
            {/* Stats bar */}
            <div className="flex flex-wrap items-center justify-between gap-2 mb-4">
              <div className="flex flex-wrap items-center gap-3 text-[11px]">
                <span className="text-[var(--text-tertiary)]">{stats.total} files</span>
                {stats.success > 0 && <span className="text-emerald-400">{stats.success} uploaded</span>}
                {stats.duplicate > 0 && <span className="text-amber-400">{stats.duplicate} duplicates</span>}
                {stats.error > 0 && <span className="text-red-400">{stats.error} failed</span>}
              </div>
              <div className="flex items-center gap-2">
                {isUploading ? (
                  <button onClick={cancelAll} className="glass-pill">
                    Cancel
                  </button>
                ) : (
                  <>
                    {stats.error > 0 && (
                      <button onClick={retryFailed} className="glass-pill">
                        Retry failed
                      </button>
                    )}
                    {finished > 0 && (
                      <button onClick={clearFinished} className="glass-pill">
                        Clear finished
                      </button>
                    )}
                  </>
                )}
                <GlassButton
                  variant="accent"
                  onClick={startUpload}
                  disabled={isUploading || stats.pending === 0}
                  className="text-[12px] py-2 px-4"
                >
                  {isUploading ? (
                    <span className="flex items-center gap-2">
                      <Loader2 size={14} className="animate-spin" /> Uploading {finished + stats.active}/{stats.total}…
                    </span>
                  ) : (
                    `Upload ${stats.pending} files`
                  )}
                </GlassButton>
              </div>
            </div>

            {stats.success > 0 && !isUploading && (
              <p className="text-[11px] text-[var(--text-tertiary)] mb-3">
                New uploads show up in the Library once they&apos;re indexed. If they don&apos;t, run
                Settings → Rescan Now.
              </p>
            )}

            {/* File list */}
            <div className="space-y-1.5">
              {uploads.map((item) => (
                <UploadRow key={item.id} item={item} />
              ))}
            </div>
          </motion.div>
        )}
      </div>
    </div>
  );
}
