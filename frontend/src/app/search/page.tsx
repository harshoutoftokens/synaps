'use client';

import { useState, useEffect, useRef } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TopBar } from '@/components/TopBar';
import { searchMedia, getSearchSuggestions, getThumbnailUrl } from '@/lib/api';
import { GlassPanel } from '@/components/glass/GlassPanel';
import { useAppStore } from '@/lib/store';
import {
  Search as SearchIcon, X, Image, Film, FileText,
  Clock, ArrowRight, AlertCircle
} from 'lucide-react';

const quickFilters = [
  { key: null, label: 'All', icon: SearchIcon },
  { key: 'image', label: 'Photos', icon: Image },
  { key: 'video', label: 'Videos', icon: Film },
  { key: 'document', label: 'Docs', icon: FileText },
];

const EMPTY_SUGGESTIONS = { files: [] as string[], directories: [] as string[] };

export default function SearchPage() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<any[]>([]);
  const [suggestions, setSuggestions] = useState(EMPTY_SUGGESTIONS);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [total, setTotal] = useState(0);
  const [page, setPage] = useState(1);
  const [filter, setFilter] = useState<string | null>(null);
  // What the current results were fetched for (null = nothing searched yet)
  const [searched, setSearched] = useState<{ q: string; filter: string | null } | null>(null);
  const [showSuggestions, setShowSuggestions] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const searchRequestRef = useRef(0);
  const openViewer = useAppStore((s) => s.openViewer);

  useEffect(() => {
    inputRef.current?.focus();
  }, []);

  useEffect(() => {
    if (query.trim().length < 1) {
      setSuggestions(EMPTY_SUGGESTIONS);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(() => {
      getSearchSuggestions(query.trim())
        .then((s) => {
          if (!cancelled) setSuggestions(s);
        })
        .catch(() => {});
    }, 200);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [query]);

  // Filter is passed explicitly: reading state right after setFilter() would see the old value
  const runSearch = async (q: string, mediaFilter: string | null) => {
    const trimmed = q.trim();
    if (!trimmed) return;
    const request = ++searchRequestRef.current;
    setLoading(true);
    setError(null);
    setShowSuggestions(false);
    try {
      const data = await searchMedia(trimmed, mediaFilter || undefined, 1);
      if (request !== searchRequestRef.current) return;
      setResults(data.results);
      setTotal(data.total);
      setPage(1);
      setSearched({ q: trimmed, filter: mediaFilter });
    } catch (err: any) {
      if (request !== searchRequestRef.current) return;
      console.error(err);
      setError(err.message || 'Search failed');
    } finally {
      if (request === searchRequestRef.current) setLoading(false);
    }
  };

  const loadMore = async () => {
    if (!searched || loadingMore) return;
    const request = searchRequestRef.current;
    setLoadingMore(true);
    try {
      const data = await searchMedia(searched.q, searched.filter || undefined, page + 1);
      if (request !== searchRequestRef.current) return;
      setResults((prev) => {
        const seen = new Set(prev.map((r) => r.id));
        return [...prev, ...data.results.filter((r: any) => !seen.has(r.id))];
      });
      setTotal(data.total);
      setPage(page + 1);
    } catch (err: any) {
      if (request === searchRequestRef.current) setError(err.message || 'Search failed');
    } finally {
      if (request === searchRequestRef.current) setLoadingMore(false);
    }
  };

  const clearSearch = () => {
    searchRequestRef.current++;
    setQuery('');
    setResults([]);
    setTotal(0);
    setSearched(null);
    setError(null);
    setLoading(false);
    setShowSuggestions(false);
  };

  return (
    <div className="min-h-screen">
      <TopBar title="Search" />

      <div className="px-4 lg:px-6 py-6 max-w-3xl mx-auto">
        {/* Search bar — glass */}
        <div className="relative mb-6">
          <div className="relative flex items-center">
            <SearchIcon size={18} className="absolute left-4 text-[var(--text-tertiary)]" />
            <input
              ref={inputRef}
              type="text"
              enterKeyHint="search"
              value={query}
              onChange={(e) => { setQuery(e.target.value); setShowSuggestions(true); }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') runSearch(query, filter);
                if (e.key === 'Escape') setShowSuggestions(false);
              }}
              onFocus={() => setShowSuggestions(true)}
              onBlur={() => setTimeout(() => setShowSuggestions(false), 150)}
              placeholder="Search files, folders, media..."
              aria-label="Search media"
              className="glass-input pl-11 pr-10"
            />
            {query && (
              <button
                onClick={clearSearch}
                aria-label="Clear search"
                className="absolute right-4 p-1 rounded-full hover:bg-[var(--glass-bg-hover)]"
              >
                <X size={14} className="text-[var(--text-tertiary)]" />
              </button>
            )}
          </div>

          {/* Suggestions dropdown — glass */}
          <AnimatePresence>
            {showSuggestions && (suggestions.files.length > 0 || suggestions.directories.length > 0) && (
              <GlassPanel
                as={motion.div as any}
                variant="elevated"
                initial={{ opacity: 0, y: -4 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -4 }}
                className="absolute top-full left-0 right-0 mt-2 rounded-2xl overflow-hidden z-30"
              >
                {suggestions.directories.map((dir) => (
                  <button
                    key={dir}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => { setQuery(dir); runSearch(dir, filter); }}
                    className="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm
                      hover:bg-[var(--glass-bg-hover)] transition-colors"
                  >
                    <SearchIcon size={14} className="text-[var(--text-tertiary)]" />
                    <span className="text-[var(--text-secondary)] truncate">{dir}</span>
                    <ArrowRight size={12} className="text-[var(--text-muted)] ml-auto" />
                  </button>
                ))}
                {suggestions.files.map((file) => (
                  <button
                    key={file}
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => { setQuery(file); runSearch(file, filter); }}
                    className="w-full flex items-center gap-3 px-4 py-2.5 text-left text-sm
                      hover:bg-[var(--glass-bg-hover)] transition-colors"
                  >
                    <Clock size={14} className="text-[var(--text-tertiary)]" />
                    <span className="text-[var(--text-secondary)] truncate">{file}</span>
                  </button>
                ))}
              </GlassPanel>
            )}
          </AnimatePresence>
        </div>

        {/* Quick filters — glass pills */}
        <div className="flex gap-2 mb-6 flex-wrap">
          {quickFilters.map((f) => {
            const isActive = filter === f.key;
            return (
              <button
                key={f.key ?? 'all'}
                aria-pressed={isActive}
                onClick={() => { setFilter(f.key); if (query.trim()) runSearch(query, f.key); }}
                className={`glass-pill ${isActive ? 'glass-pill-active' : ''}`}
              >
                {f.label}
              </button>
            );
          })}
        </div>

        {error && (
          <div className="flex items-center gap-2 mb-4 px-3 py-2.5 rounded-xl bg-red-500/10 border border-red-500/15" role="alert">
            <AlertCircle size={14} className="text-red-400 shrink-0" />
            <p className="text-[12px] text-red-400">{error}</p>
          </div>
        )}

        {/* Results */}
        {loading ? (
          <div className="flex justify-center py-20">
            <div className="w-8 h-8 rounded-full border-2 border-[var(--accent)]/20 border-t-[var(--accent)] animate-spin" />
          </div>
        ) : results.length > 0 ? (
          <div>
            <p className="text-[11px] text-[var(--text-tertiary)] mb-3">
              {total.toLocaleString()} results found{results.length < total ? ` · showing ${results.length.toLocaleString()}` : ''}
            </p>
            <div className="space-y-1">
              {results.map((item) => (
                <button
                  key={item.id}
                  onClick={() => openViewer(item.id, results.map((r) => r.id))}
                  className="w-full flex items-center gap-3 px-3 py-2.5 rounded-xl animate-fade-in
                    hover:bg-[var(--glass-bg-hover)] transition-colors text-left"
                >
                  <div className="w-10 h-10 rounded-lg overflow-hidden bg-[var(--glass-bg)] shrink-0 border border-[var(--glass-border)]">
                    <img
                      src={getThumbnailUrl(item.id)}
                      alt=""
                      className="w-full h-full object-cover"
                      loading="lazy"
                      decoding="async"
                    />
                  </div>
                  <div className="flex-1 min-w-0">
                    <p className="text-[13px] text-[var(--text-primary)] truncate">{item.filename}</p>
                    <p className="text-[10px] text-[var(--text-tertiary)] truncate">{item.directory}</p>
                  </div>
                  <span className="text-[10px] text-[var(--text-muted)] uppercase shrink-0 font-medium">
                    {(item.extension || '').replace('.', '')}
                  </span>
                </button>
              ))}
            </div>
            {results.length < total && (
              <div className="flex justify-center mt-4">
                <button onClick={loadMore} disabled={loadingMore} className="glass-pill">
                  {loadingMore ? 'Loading…' : 'Load more results'}
                </button>
              </div>
            )}
          </div>
        ) : searched && !error ? (
          <div className="flex flex-col items-center justify-center py-20">
            <SearchIcon size={32} className="text-[var(--text-muted)] mb-3" />
            <p className="text-sm text-[var(--text-tertiary)]">No results for &ldquo;{searched.q}&rdquo;</p>
          </div>
        ) : !error ? (
          <div className="flex flex-col items-center justify-center py-20">
            <SearchIcon size={32} className="text-[var(--text-muted)] mb-3" />
            <p className="text-sm text-[var(--text-secondary)]">Search your media library</p>
            <p className="text-[11px] text-[var(--text-tertiary)] mt-1">Search by filename, folder, or extension</p>
          </div>
        ) : null}
      </div>
    </div>
  );
}
