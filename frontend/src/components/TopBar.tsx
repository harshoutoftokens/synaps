'use client';

import { useAppStore } from '@/lib/store';
import { GlassSegmentedControl } from '@/components/glass/GlassSegmentedControl';
import { Menu, Search, SlidersHorizontal } from 'lucide-react';
import Link from 'next/link';

interface TopBarProps {
  title: string;
  subtitle?: string;
  showViewControls?: boolean;
  showSourcesButton?: boolean;
  children?: React.ReactNode;
}

const viewOptions = [
  { key: 'timeline', label: 'Months' },
  { key: 'gallery', label: 'All Photos' },
];

export function TopBar({
  title,
  subtitle,
  showViewControls = false,
  showSourcesButton = false,
  children,
}: TopBarProps) {
  // Select only what the bar shows: a bare useAppStore() re-renders on every store change
  const toggleSidebar = useAppStore((s) => s.toggleSidebar);
  const activeView = useAppStore((s) => s.activeView);
  const setActiveView = useAppStore((s) => s.setActiveView);
  const activeSources = useAppStore((s) => s.activeSources);

  return (
    <header
      className="sticky top-0 z-20 px-4 lg:px-6 py-4
        bg-[var(--bg-deep)]/70 backdrop-blur-[20px]"
      style={{
        WebkitBackdropFilter: 'blur(20px)',
      }}
    >
      <div className="flex items-center justify-between gap-4">
        {/* Left: Menu + Title */}
        <div className="flex items-center gap-3 min-w-0">
          <button
            onClick={toggleSidebar}
            aria-label="Open menu"
            className="p-2 -ml-2 rounded-xl hover:bg-[var(--glass-bg-hover)] transition-colors lg:hidden"
          >
            <Menu size={20} className="text-[var(--text-secondary)]" />
          </button>
          <div className="min-w-0">
            <h1 className="text-3xl font-extrabold tracking-tight text-[var(--text-primary)] truncate">
              {title}
            </h1>
            {subtitle && (
              <p className="text-xs font-medium text-[var(--text-tertiary)] mt-0.5 truncate">{subtitle}</p>
            )}
          </div>
        </div>

        {/* Center: Segmented Control (Library page only) */}
        {showViewControls && (
          <div className="hidden sm:flex items-center">
            <GlassSegmentedControl
              options={viewOptions}
              value={activeView}
              onChange={(key) => setActiveView(key as 'timeline' | 'gallery')}
            />
          </div>
        )}

        {/* Right: Action buttons */}
        <div className="flex items-center gap-1">
          {showSourcesButton && activeSources.size > 0 && (
            <div className="glass-pill glass-pill-active mr-1 text-[11px]">
              <SlidersHorizontal size={12} />
              {activeSources.size} source{activeSources.size > 1 ? 's' : ''}
            </div>
          )}
          {children}
          <Link
            href="/search"
            aria-label="Search"
            className="inline-flex items-center justify-center transition-all duration-200 p-2 rounded-xl
              text-[var(--text-secondary)] hover:bg-[var(--glass-bg-hover)] hover:text-[var(--text-primary)]"
          >
            <Search size={18} className="text-[var(--text-secondary)]" />
          </Link>
        </div>
      </div>

      {/* Mobile view toggle */}
      {showViewControls && (
        <div className="sm:hidden mt-3 flex justify-center">
          <GlassSegmentedControl
            options={viewOptions}
            value={activeView}
            onChange={(key) => setActiveView(key as 'timeline' | 'gallery')}
          />
        </div>
      )}
    </header>
  );
}
