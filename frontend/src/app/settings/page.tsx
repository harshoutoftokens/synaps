'use client';

import { useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import { useTheme } from 'next-themes';
import { TopBar } from '@/components/TopBar';
import { GlassPanel } from '@/components/glass/GlassPanel';
import { GlassButton } from '@/components/glass/GlassButton';
import {
  getSettings, updateSettings, getStorageUsage, triggerScan,
  getApiToken, setApiToken, isValidApiToken, verifyApiToken,
} from '@/lib/api';
import {
  HardDrive, Image, Film, FileText, Trash2,
  RefreshCw, Moon, Sun, Monitor, FolderSearch, Loader2, KeyRound
} from 'lucide-react';

/** Optional API token (only needed when the server sets SYNAPS_API_TOKEN). */
function ApiTokenSection() {
  const [savedToken, setSavedToken] = useState<string | null>(null);
  const [value, setValue] = useState('');
  const [status, setStatus] = useState<{ tone: 'ok' | 'warn' | 'error'; text: string } | null>(null);
  const [checking, setChecking] = useState(false);

  useEffect(() => {
    setSavedToken(getApiToken());
  }, []);

  const check = async () => {
    setChecking(true);
    const result = await verifyApiToken();
    setChecking(false);
    if (result === 'ok') setStatus({ tone: 'ok', text: 'The server accepted this browser’s requests.' });
    else if (result === 'rejected') setStatus({ tone: 'error', text: 'The server rejected the token.' });
    else setStatus({ tone: 'warn', text: 'Couldn’t reach the server to verify the token.' });
  };

  const save = async (e: React.FormEvent) => {
    e.preventDefault();
    const token = value.trim();
    if (!token) return;
    if (!isValidApiToken(token)) {
      setStatus({ tone: 'error', text: 'Tokens can’t contain spaces, quotes, commas, semicolons or backslashes.' });
      return;
    }
    setApiToken(token);
    setSavedToken(token);
    setValue('');
    await check();
  };

  const clear = () => {
    setApiToken(null);
    setSavedToken(null);
    setStatus(null);
  };

  const statusColor = status?.tone === 'ok' ? 'text-emerald-400' : status?.tone === 'warn' ? 'text-amber-400' : 'text-red-400';

  return (
    <GlassPanel
      as={motion.section as any}
      variant="card"
      initial={{ opacity: 0, y: 20 }}
      animate={{ opacity: 1, y: 0 }}
      transition={{ delay: 0.25 }}
    >
      <h2 className="text-[13px] font-semibold text-[var(--text-primary)] mb-2 flex items-center gap-2">
        <KeyRound size={16} className="text-[var(--accent)]" />
        API Token
      </h2>
      <p className="text-[12px] text-[var(--text-tertiary)] mb-4">
        Only needed if the server was started with <span className="font-mono">SYNAPS_API_TOKEN</span>.
        Stored in a cookie in this browser.
      </p>
      <div className="flex items-center justify-between gap-3 mb-3 px-3 py-2.5 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
        <span className="text-[12px] text-[var(--text-secondary)] font-mono truncate">
          {savedToken ? `••••••••${savedToken.slice(-4)}` : 'No token set'}
        </span>
        {savedToken && (
          <div className="flex items-center gap-3 shrink-0">
            <button onClick={check} disabled={checking} className="text-[12px] font-medium text-[var(--accent)] hover:underline disabled:opacity-50">
              {checking ? 'Checking…' : 'Verify'}
            </button>
            <button onClick={clear} className="text-[12px] font-medium text-red-400 hover:underline">
              Clear
            </button>
          </div>
        )}
      </div>
      <form onSubmit={save} className="flex gap-2">
        <input
          type="password"
          autoComplete="off"
          spellCheck={false}
          value={value}
          onChange={(e) => { setValue(e.target.value); setStatus(null); }}
          placeholder={savedToken ? 'Replace token' : 'Paste token'}
          aria-label="API token"
          className="glass-input flex-1 min-w-0"
        />
        <GlassButton variant="accent" type="submit" disabled={!value.trim()}>
          Save
        </GlassButton>
      </form>
      {status && <p className={`text-[11px] mt-2 ${statusColor}`}>{status.text}</p>}
    </GlassPanel>
  );
}

export default function SettingsPage() {
  const [settings, setSettings] = useState<any>({});
  const [usage, setUsage] = useState<any>(null);
  const [scanning, setScanning] = useState(false);
  const { theme, setTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
    getSettings().then(setSettings).catch(console.error);
    getStorageUsage().then(setUsage).catch(console.error);
  }, []);

  const handleScan = async () => {
    setScanning(true);
    try {
      await triggerScan();
      // Re-fetch usage after a delay
      setTimeout(() => {
        getStorageUsage().then(setUsage).catch(console.error);
        setScanning(false);
      }, 3000);
    } catch (err: any) {
      setScanning(false);
      alert(`Couldn't start the scan: ${err.message || 'Unknown error'}`);
    }
  };

  const handleThemeChange = (newTheme: string) => {
    setTheme(newTheme);
    // The theme itself lives in localStorage (next-themes); the server copy is best-effort
    updateSettings({ theme: newTheme }).catch((err) => console.warn('Failed to save theme:', err));
  };

  const themes = [
    { key: 'light', label: 'Light', icon: Sun },
    { key: 'dark', label: 'Dark', icon: Moon },
    { key: 'system', label: 'System', icon: Monitor },
  ];

  return (
    <div className="min-h-screen">
      <TopBar title="Settings" />

      <div className="px-4 lg:px-6 py-6 max-w-2xl mx-auto space-y-5">
        {/* Storage Usage */}
        <GlassPanel
          as={motion.section as any}
          variant="card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
        >
          <h2 className="text-[13px] font-semibold text-[var(--text-primary)] mb-4 flex items-center gap-2">
            <HardDrive size={16} className="text-[var(--accent)]" />
            Storage Overview
          </h2>

          {usage ? (
            <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
              {[
                { label: 'Total Files', value: usage.total_files?.toLocaleString(), icon: HardDrive, color: 'text-[var(--accent)]' },
                { label: 'Photos', value: usage.images?.toLocaleString(), icon: Image, color: 'text-blue-400' },
                { label: 'Videos', value: usage.videos?.toLocaleString(), icon: Film, color: 'text-purple-400' },
                { label: 'Documents', value: usage.documents?.toLocaleString(), icon: FileText, color: 'text-amber-400' },
              ].map((stat) => (
                <div key={stat.label} className="text-center p-3 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                  <stat.icon size={18} className={`${stat.color} mx-auto mb-2`} />
                  <div className="text-lg font-bold text-[var(--text-primary)]">{stat.value}</div>
                  <div className="text-[10px] text-[var(--text-tertiary)]">{stat.label}</div>
                </div>
              ))}
            </div>
          ) : (
            <div className="h-24 flex items-center justify-center">
              <div className="w-6 h-6 rounded-full border-2 border-[var(--accent)]/20 border-t-[var(--accent)] animate-spin" />
            </div>
          )}

          {usage && (
            <div className="mt-4 grid grid-cols-3 gap-3 text-center text-xs">
              <div className="p-2.5 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                <div className="font-semibold text-[var(--text-primary)]">{usage.total_indexed_human}</div>
                <div className="text-[var(--text-tertiary)] text-[10px]">Indexed</div>
              </div>
              <div className="p-2.5 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                <div className="font-semibold text-[var(--text-primary)]">{usage.thumbnail_cache_human}</div>
                <div className="text-[var(--text-tertiary)] text-[10px]">Thumbnails</div>
              </div>
              <div className="p-2.5 rounded-xl bg-[var(--glass-bg)] border border-[var(--glass-border)]">
                <div className="font-semibold text-[var(--text-primary)]">{usage.trash_size_human}</div>
                <div className="text-[var(--text-tertiary)] text-[10px]">Trash</div>
              </div>
            </div>
          )}
        </GlassPanel>

        {/* Theme */}
        <GlassPanel
          as={motion.section as any}
          variant="card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.1 }}
        >
          <h2 className="text-[13px] font-semibold text-[var(--text-primary)] mb-4">
            Appearance
          </h2>
          <div className="flex gap-3">
            {themes.map((t) => {
              const Icon = t.icon;
              const isActive = mounted && theme === t.key;
              return (
                <button
                  key={t.key}
                  onClick={() => handleThemeChange(t.key)}
                  className={`flex-1 flex flex-col items-center gap-2 p-4 rounded-2xl transition-all duration-200 border
                    ${isActive
                      ? 'bg-[var(--accent-muted)] border-[rgba(108,138,255,0.2)] text-[var(--accent-light)]'
                      : 'bg-[var(--glass-bg)] border-[var(--glass-border)] text-[var(--text-tertiary)] hover:bg-[var(--glass-bg-hover)]'
                    }`}
                >
                  <Icon size={20} />
                  <span className="text-[11px] font-medium">{t.label}</span>
                </button>
              );
            })}
          </div>
        </GlassPanel>

        {/* Scan */}
        <GlassPanel
          as={motion.section as any}
          variant="card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.2 }}
        >
          <h2 className="text-[13px] font-semibold text-[var(--text-primary)] mb-2 flex items-center gap-2">
            <FolderSearch size={16} className="text-[var(--accent)]" />
            Media Scanner
          </h2>
          <p className="text-[12px] text-[var(--text-tertiary)] mb-4">
            Rescan your NAS to index new files and generate thumbnails.
          </p>
          <GlassButton
            variant="accent"
            onClick={handleScan}
            disabled={scanning}
          >
            {scanning ? (
              <>
                <Loader2 size={16} className="animate-spin" />
                Scanning...
              </>
            ) : (
              <>
                <RefreshCw size={16} />
                Rescan Now
              </>
            )}
          </GlassButton>
        </GlassPanel>

        {/* API token */}
        <ApiTokenSection />

        {/* Paths */}
        <GlassPanel
          as={motion.section as any}
          variant="card"
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.3 }}
        >
          <h2 className="text-[13px] font-semibold text-[var(--text-primary)] mb-4">
            Configuration
          </h2>
          <div className="space-y-3">
            {[
              { label: 'Storage Path', value: settings.storage_path },
              { label: 'Thumbnail Cache', value: settings.thumbnail_dir },
              { label: 'Trash Directory', value: settings.trash_dir },
            ].map((item) => (
              <div key={item.label}>
                <label className="text-[11px] text-[var(--text-tertiary)] mb-1.5 block">{item.label}</label>
                <div className="px-3 py-2.5 rounded-xl bg-[var(--glass-bg)] text-[12px] text-[var(--text-secondary)] font-mono border border-[var(--glass-border)]">
                  {item.value || 'Not set'}
                </div>
              </div>
            ))}
          </div>
        </GlassPanel>

        {/* About */}
        <motion.section
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          transition={{ delay: 0.4 }}
          className="text-center py-8"
        >
          <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-[var(--accent)] to-[var(--accent-dark)] flex items-center justify-center mx-auto mb-3 shadow-lg shadow-[var(--accent-glow)]">
            <span className="text-white text-lg font-bold">S</span>
          </div>
          <h3 className="text-sm font-semibold text-[var(--text-primary)]">Synaps v1.0</h3>
          <p className="text-[11px] text-[var(--text-tertiary)] mt-1">Personal NAS Media Cloud</p>
          <p className="text-[10px] text-[var(--text-muted)] mt-0.5">Local Network Only</p>
        </motion.section>
      </div>
    </div>
  );
}
