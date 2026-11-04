'use client';

import Link from 'next/link';
import { usePathname, useRouter } from 'next/navigation';
import { useEffect, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useAppStore } from '@/lib/store';
import { formatBytes, getSystemNow, type SystemNow } from '@/lib/system';
import {
  LayoutGrid, Folder, Search, Upload, Trash2, Settings, X,
  Smartphone, Monitor, Laptop, Star, Camera, Gauge
} from 'lucide-react';

const LIBRARY = '/library';

const mainNav = [
  { href: '/', label: 'Dashboard', icon: Gauge },
  { href: LIBRARY, label: 'Library', icon: LayoutGrid },
];

const pinnedItems = [
  { key: 'favorite', label: 'Favorites', icon: Star, type: 'filter' as const },
  { key: 'screenshot', label: 'Screenshots', icon: Camera, type: 'filter' as const },
  { href: '/finder', label: 'Finder', icon: Folder, type: 'nav' as const },
  { href: '/sync', label: 'Sync', icon: Upload, type: 'nav' as const },
];

const sourceItems = [
  { key: 'iphone', label: 'iPhone', icon: Smartphone },
  { key: 'mac', label: 'Mac', icon: Laptop },
  { key: 'windows', label: 'Windows', icon: Monitor },
];

const utilityItems = [
  { href: '/search', label: 'Search', icon: Search },
  { href: '/trash', label: 'Trash', icon: Trash2 },
  { href: '/settings', label: 'Settings', icon: Settings },
];

export function Sidebar() {
  // The static export uses trailing slashes (/library/); compare paths without them
  const rawPath = usePathname() ?? '/';
  const pathname = rawPath.length > 1 ? rawPath.replace(/\/$/, '') : rawPath;
  const router = useRouter();
  const sidebarOpen = useAppStore((s) => s.sidebarOpen);
  const setSidebarOpen = useAppStore((s) => s.setSidebarOpen);
  const activeFilter = useAppStore((s) => s.activeFilter);
  const setFilter = useAppStore((s) => s.setFilter);
  const activeSources = useAppStore((s) => s.activeSources);
  const toggleSource = useAppStore((s) => s.toggleSource);

  const [disk, setDisk] = useState<SystemNow['disk'] | null>(null);

  // The storage volume's real usage. /system/now is cheap (statvfs, no tree walk), and the
  // dashboard keeps its own live copy, so the sidebar reads it once per load.
  useEffect(() => {
    getSystemNow()
      .then((now) => setDisk(now.disk))
      .catch(() => {});
  }, []);

  const handleNavClick = () => {
    if (window.innerWidth < 1024) setSidebarOpen(false);
  };

  const handleFilterClick = (key: string) => {
    setFilter(activeFilter === key ? null : key);
    if (window.innerWidth < 1024) setSidebarOpen(false);
  };

  const handleSourceClick = (key: string) => {
    toggleSource(key);
  };

  const isNavActive = (href: string) => {
    return pathname === href;
  };

  return (
    <>
      {/* Mobile overlay */}
      <AnimatePresence>
        {sidebarOpen && (
          <motion.div
            initial={{ opacity: 0 }}
            animate={{ opacity: 1 }}
            exit={{ opacity: 0 }}
            className="fixed inset-0 bg-black/40 backdrop-blur-sm z-40 lg:hidden"
            onClick={() => setSidebarOpen(false)}
          />
        )}
      </AnimatePresence>

      {/* Sidebar */}
      <aside
        className={`fixed left-2 top-2 bottom-2 w-[var(--sidebar-width)] z-50 lg:z-30
          glass-panel-sidebar flex flex-col overflow-hidden transition-transform duration-300
          rounded-[20px] shadow-lg
          ${sidebarOpen ? 'translate-x-0' : '-translate-x-[110%] lg:translate-x-0'}`}
      >
        {/* ── App Header ── */}
        <div className="flex items-center justify-between px-4 pt-5 pb-3">
          <div className="flex items-center gap-2.5">
            <div className="w-8 h-8 rounded-xl bg-gradient-to-br from-[var(--accent)] to-[var(--accent-dark)] flex items-center justify-center shadow-lg shadow-[var(--accent-glow)]">
              <span className="text-white text-sm font-bold">S</span>
            </div>
            <div>
              <div className="text-[14px] font-semibold tracking-tight text-[var(--text-primary)]">
                Synaps
              </div>
              <div className="text-[11px] text-[var(--text-secondary)] -mt-0.5">
                Personal Media Cloud
              </div>
            </div>
          </div>
          <button
            onClick={() => setSidebarOpen(false)}
            aria-label="Close menu"
            className="lg:hidden p-1.5 rounded-lg hover:bg-[var(--glass-bg-hover)] transition-colors"
          >
            <X size={16} className="text-[var(--text-tertiary)]" />
          </button>
        </div>

        <div className="flex-1 overflow-y-auto no-scrollbar pb-6">
          {/* ── Main Nav ── */}
          <nav className="px-2.5 mt-2 space-y-0.5">
            {mainNav.map((item) => {
              const active = isNavActive(item.href);
              const Icon = item.icon;
              return (
                <Link
                  key={item.label}
                  href={item.href}
                  onClick={handleNavClick}
                  className={`nav-item ${active ? 'nav-item-active' : ''}`}
                >
                  <Icon size={16} strokeWidth={active ? 2 : 1.5} />
                  {item.label}
                </Link>
              );
            })}
          </nav>

          {/* ── Pinned ── */}
          <div className="mt-5 mb-1">
            <div className="section-label px-4 text-[11px] font-semibold text-[var(--text-tertiary)] uppercase tracking-wider">Pinned</div>
          </div>
          <nav className="px-2.5 space-y-0.5">
            {pinnedItems.map((item) => {
              const Icon = item.icon;
              if (item.type === 'nav') {
                const active = isNavActive(item.href);
                return (
                  <Link
                    key={item.label}
                    href={item.href}
                    onClick={handleNavClick}
                    className={`nav-item ${active ? 'nav-item-active' : ''}`}
                  >
                    <Icon size={16} strokeWidth={active ? 2 : 1.5} />
                    {item.label}
                  </Link>
                );
              } else {
                const active = activeFilter === item.key;
                return (
                  <button
                    key={item.label}
                    aria-pressed={active}
                    onClick={() => {
                      handleFilterClick(item.key);
                      // If we are applying a filter but not on the library page, navigate to library
                      if (pathname !== LIBRARY) {
                        router.push(LIBRARY);
                      }
                    }}
                    className={`nav-item w-full ${active ? 'nav-item-active' : ''}`}
                  >
                    <Icon size={16} strokeWidth={active ? 2 : 1.5} />
                    {item.label}
                  </button>
                );
              }
            })}
          </nav>

          {/* ── Sources ── */}
          <div className="mt-5 mb-1">
            <div className="section-label px-4 text-[11px] font-semibold text-[var(--text-tertiary)] uppercase tracking-wider">Sources</div>
          </div>
          <nav className="px-2.5 space-y-0.5">
            {sourceItems.map((item) => {
              const active = activeSources.has(item.key);
              const Icon = item.icon;
              return (
                <button
                  key={item.key}
                  aria-pressed={active}
                  onClick={() => {
                    handleSourceClick(item.key);
                    // If we are applying a source filter but not on the library page, navigate to library
                    if (pathname !== LIBRARY) {
                      router.push(LIBRARY);
                    }
                  }}
                  className={`nav-item w-full ${active ? 'nav-item-active' : ''}`}
                >
                  <Icon size={16} strokeWidth={active ? 2 : 1.5} />
                  {item.label}
                </button>
              );
            })}
          </nav>

          {/* ── Utilities ── */}
          <div className="mt-5 mb-1">
            <div className="section-label px-4 text-[11px] font-semibold text-[var(--text-tertiary)] uppercase tracking-wider">Utilities</div>
          </div>
          <nav className="px-2.5 space-y-0.5">
            {utilityItems.map((item) => {
              const active = isNavActive(item.href);
              const Icon = item.icon;
              return (
                <Link
                  key={item.label}
                  href={item.href}
                  onClick={handleNavClick}
                  className={`nav-item ${active ? 'nav-item-active' : ''}`}
                >
                  <Icon size={16} strokeWidth={active ? 2 : 1.5} />
                  {item.label}
                </Link>
              );
            })}
          </nav>
        </div>

        {/* ── Storage Indicator ── */}
        <div className="px-4 py-4 border-t border-[var(--glass-border)] bg-[var(--bg-deep)]/20">
          <div className="flex items-center justify-between mb-2">
            <span className="text-[12px] font-medium text-[var(--text-secondary)]">Disk</span>
            {disk?.free != null && (
              <span className="text-[12px] text-[var(--text-secondary)]">{formatBytes(disk.free)} free</span>
            )}
          </div>
          <div className="storage-bar" role="meter" aria-label="Disk used" aria-valuemin={0} aria-valuemax={100}
            aria-valuenow={disk?.percent ?? undefined}>
            {/* Same thresholds and colours as the dashboard's Disk tile */}
            <div className="storage-bar-fill" style={{
              width: `${disk?.percent ?? 0}%`,
              background: (disk?.percent ?? 0) >= 95 ? 'var(--w-red-fill)'
                : (disk?.percent ?? 0) >= 85 ? 'var(--w-amber-fill)' : 'var(--w-green-fill)',
            }} />
          </div>
          <div className="mt-1.5 text-[12px] text-[var(--text-secondary)]">
            {disk?.used != null && disk.total != null
              ? `${formatBytes(disk.used)} of ${formatBytes(disk.total)} used`
              : '—'}
          </div>
        </div>
      </aside>
    </>
  );
}
