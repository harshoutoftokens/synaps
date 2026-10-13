'use client';

import { useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import { TopBar } from '@/components/TopBar';
import { GlassPanel } from '@/components/glass/GlassPanel';
import { getTrash, restoreFromTrash, permanentDelete } from '@/lib/api';
import { Trash2, RotateCcw, Clock, AlertCircle } from 'lucide-react';

export default function TrashPage() {
  const [items, setItems] = useState<any[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);

  const fetchTrash = async (showSpinner = true) => {
    if (showSpinner) setLoading(true);
    try {
      const data = await getTrash();
      setItems(data.items);
      setError(null);
    } catch (err: any) {
      console.error(err);
      setError(err.message || 'Failed to load trash');
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { fetchTrash(); }, []);

  const handleRestore = async (id: string) => {
    if (busyId) return;
    setBusyId(id);
    try {
      await restoreFromTrash(id);
      await fetchTrash(false);
    } catch (err: any) {
      setError(`Restore failed: ${err.message || 'Unknown error'}`);
    } finally {
      setBusyId(null);
    }
  };

  const handlePermanentDelete = async (id: string) => {
    if (busyId) return;
    if (!confirm('Permanently delete this file? This cannot be undone.')) return;
    setBusyId(id);
    try {
      await permanentDelete(id);
      await fetchTrash(false);
    } catch (err: any) {
      setError(`Delete failed: ${err.message || 'Unknown error'}`);
    } finally {
      setBusyId(null);
    }
  };

  return (
    <div className="min-h-screen">
      <TopBar title="Trash" subtitle="Files are auto-deleted after 30 days" />

      <div className="px-4 lg:px-6 py-6 max-w-3xl mx-auto">
        {error && (
          <div className="flex items-center gap-2 mb-4 px-3 py-2.5 rounded-xl bg-red-500/10 border border-red-500/15" role="alert">
            <AlertCircle size={14} className="text-red-400 shrink-0" />
            <p className="text-[12px] text-red-400 flex-1">{error}</p>
            <button onClick={() => fetchTrash()} className="text-[12px] font-medium text-[var(--accent)] hover:underline shrink-0">
              Retry
            </button>
          </div>
        )}

        {loading ? (
          <div className="flex justify-center py-20">
            <div className="w-8 h-8 rounded-full border-2 border-[var(--accent)]/20 border-t-[var(--accent)] animate-spin" />
          </div>
        ) : items.length > 0 ? (
          <div className="space-y-2">
            {items.map((item) => (
              <GlassPanel
                as={motion.div as any}
                key={item.id}
                initial={{ opacity: 0, y: 10 }}
                animate={{ opacity: busyId === item.id ? 0.5 : 1, y: 0 }}
                className="flex items-center gap-3 px-4 py-3 rounded-2xl"
              >
                {item.thumbnail_url ? (
                  <div className="w-10 h-10 rounded-lg overflow-hidden bg-[var(--glass-bg)] shrink-0 border border-[var(--glass-border)]">
                    <img
                      src={item.thumbnail_url}
                      alt=""
                      className="w-full h-full object-cover"
                      loading="lazy"
                      decoding="async"
                    />
                  </div>
                ) : (
                  <div className="w-10 h-10 rounded-lg bg-red-500/10 flex items-center justify-center shrink-0">
                    <Trash2 size={18} className="text-red-400/60" />
                  </div>
                )}
                <div className="flex-1 min-w-0">
                  <p className="text-[13px] text-[var(--text-primary)] truncate">{item.filename}</p>
                  <div className="flex items-center gap-2 mt-0.5">
                    <Clock size={10} className="text-[var(--text-muted)]" />
                    <span className="text-[10px] text-[var(--text-tertiary)]">
                      {item.days_remaining} days remaining
                    </span>
                  </div>
                </div>
                <div className="flex items-center gap-1 shrink-0">
                  <button
                    onClick={() => handleRestore(item.id)}
                    disabled={busyId !== null}
                    className="p-2 rounded-xl hover:bg-emerald-500/10 transition-colors group disabled:opacity-40"
                    title="Restore"
                    aria-label={`Restore ${item.filename}`}
                  >
                    <RotateCcw size={14} className="text-[var(--text-tertiary)] group-hover:text-emerald-400" />
                  </button>
                  <button
                    onClick={() => handlePermanentDelete(item.id)}
                    disabled={busyId !== null}
                    className="p-2 rounded-xl hover:bg-red-500/10 transition-colors group disabled:opacity-40"
                    title="Delete permanently"
                    aria-label={`Delete ${item.filename} permanently`}
                  >
                    <Trash2 size={14} className="text-[var(--text-tertiary)] group-hover:text-red-400" />
                  </button>
                </div>
              </GlassPanel>
            ))}
          </div>
        ) : !error && (
          <motion.div
            initial={{ opacity: 0, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            className="flex flex-col items-center justify-center py-20"
          >
            <div className="w-14 h-14 rounded-2xl bg-[var(--glass-bg)] flex items-center justify-center mb-4 border border-[var(--glass-border)]">
              <Trash2 size={22} className="text-[var(--text-tertiary)]" />
            </div>
            <h3 className="text-sm font-semibold text-[var(--text-primary)] mb-1">Trash is empty</h3>
            <p className="text-[11px] text-[var(--text-tertiary)]">Deleted files will appear here</p>
          </motion.div>
        )}
      </div>
    </div>
  );
}
