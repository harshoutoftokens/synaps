'use client';

import { useEffect, useState, useCallback, useRef, useMemo } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { TopBar } from '@/components/TopBar';
import { MediaGrid, type MediaItem } from '@/components/MediaGrid';
import { useAppStore } from '@/lib/store';
import { getMedia, getMediaStats } from '@/lib/api';
import { AlertCircle, ChevronRight, Star } from 'lucide-react';

interface TimelineGroup {
  year: number;
  month: number;
  month_name: string;
  items: MediaItem[];
}

const groupKey = (g: { year: number; month: number }) => `${g.year}-${g.month}`;

// Merge the next page into the month groups. Only groups that receive items get new objects,
// so the (memoized) grids of every other month don't re-render.
function mergeGroups(prev: TimelineGroup[], incoming: TimelineGroup[]): TimelineGroup[] {
  const merged = prev.slice();
  const indexByKey = new Map(merged.map((g, i) => [groupKey(g), i]));
  for (const group of incoming) {
    const i = indexByKey.get(groupKey(group));
    if (i === undefined) {
      if (group.items.length > 0) {
        indexByKey.set(groupKey(group), merged.length);
        merged.push(group);
      }
      continue;
    }
    const existingIds = new Set(merged[i].items.map((item) => item.id));
    const newItems = group.items.filter((item) => !existingIds.has(item.id));
    if (newItems.length > 0) merged[i] = { ...merged[i], items: merged[i].items.concat(newItems) };
  }
  merged.sort((a, b) => {
    if (a.year !== b.year) return b.year - a.year;
    return b.month - a.month;
  });
  return merged;
}

export default function MediaBrowser() {
  // Data State
  const [timelineGroups, setTimelineGroups] = useState<TimelineGroup[]>([]);
  const [galleryItems, setGalleryItems] = useState<MediaItem[]>([]);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [hasMore, setHasMore] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [stats, setStats] = useState<any>(null);

  // Timeline Hierarchy State
  const [collapsedYears, setCollapsedYears] = useState<Set<number>>(new Set());
  const [expandedMonths, setExpandedMonths] = useState<Set<string>>(new Set());
  const [hasInitializedState, setHasInitializedState] = useState(false);

  // Gallery Sticky Date State
  const [activeDateHeader, setActiveDateHeader] = useState<string | null>(null);

  const activeFilter = useAppStore((s) => s.activeFilter);
  const activeView = useAppStore((s) => s.activeView);
  const activeSources = useAppStore((s) => s.activeSources);
  const observerRef = useRef<HTMLDivElement>(null);

  // Pagination bookkeeping lives in refs so the observer callback and late responses see
  // current values. Every reset bumps the generation; responses from older ones are dropped
  // (otherwise a slow page from the previous filter gets appended to the new results).
  const generationRef = useRef(0);
  const pageRef = useRef(0);
  const inFlightRef = useRef(false);
  const hasMoreRef = useRef(true);
  const groupsRef = useRef<TimelineGroup[]>([]);
  groupsRef.current = timelineGroups;
  const pageAddedGroupsRef = useRef(false);
  const autoLoadsRef = useRef(0);

  const fetchPage = useCallback(async (reset: boolean) => {
    if (!reset && (inFlightRef.current || !hasMoreRef.current)) return;
    const generation = reset ? ++generationRef.current : generationRef.current;
    const pageNum = reset ? 1 : pageRef.current + 1;
    inFlightRef.current = true;
    if (reset) {
      setLoading(true);
    } else {
      setLoadingMore(true);
    }
    setError(null);

    try {
      const params: any = {
        page: pageNum,
        // Timeline pages mostly land in collapsed months: bigger pages = fewer round trips
        per_page: activeView === 'gallery' ? 100 : 200,
        view: activeView
      };

      if (activeFilter) params.media_type = activeFilter;
      if (activeSources.size > 0) {
        params.sources = Array.from(activeSources).join(',');
      }

      const data = await getMedia(params);
      if (generation !== generationRef.current) return;

      if (activeView === 'timeline') {
        const known = new Set(reset ? [] : groupsRef.current.map(groupKey));
        pageAddedGroupsRef.current = (data.groups || []).some(
          (g: TimelineGroup) => g.items.length > 0 && !known.has(groupKey(g))
        );
        setTimelineGroups((prev) => (reset ? data.groups || [] : mergeGroups(prev, data.groups || [])));
      } else {
        setGalleryItems((prev) => {
          if (reset) return data.items || [];
          const existingIds = new Set(prev.map((i) => i.id));
          const newItems = (data.items || []).filter((item: MediaItem) => !existingIds.has(item.id));
          return [...prev, ...newItems];
        });
      }

      pageRef.current = pageNum;
      hasMoreRef.current = pageNum < data.total_pages;
      setHasMore(hasMoreRef.current);
    } catch (err: any) {
      if (generation !== generationRef.current) return;
      console.error('Failed to fetch media:', err);
      setError(err?.message || 'Failed to load media');
    } finally {
      if (generation === generationRef.current) {
        inFlightRef.current = false;
        setLoading(false);
        setLoadingMore(false);
      }
    }
  }, [activeFilter, activeView, activeSources]);

  // Reset when filter, viewType, or sources change
  useEffect(() => {
    pageRef.current = 0;
    hasMoreRef.current = true;
    autoLoadsRef.current = 0;
    setTimelineGroups([]);
    setGalleryItems([]);
    setHasMore(true);
    setHasInitializedState(false);
    fetchPage(true);
  }, [fetchPage]);

  useEffect(() => {
    getMediaStats().then(setStats).catch(console.error);
  }, []);

  // Transform flat month groups into year-based groups for Timeline
  const yearGroups = useMemo(() => {
    if (activeView !== 'timeline') return [];
    const grouped = new Map<number, { year: number; months: TimelineGroup[]; totalItems: number }>();

    for (const group of timelineGroups) {
      if (!grouped.has(group.year)) {
        grouped.set(group.year, { year: group.year, months: [], totalItems: 0 });
      }
      const yearObj = grouped.get(group.year)!;
      yearObj.months.push(group);
      yearObj.totalItems += group.items.length;
    }

    return Array.from(grouped.values()).sort((a, b) => b.year - a.year);
  }, [timelineGroups, activeView]);

  // Auto-collapse logic for Timeline
  useEffect(() => {
    if (activeView === 'timeline' && yearGroups.length > 0 && !hasInitializedState) {
      const latestYear = yearGroups[0].year;
      const latestMonthKey = groupKey(yearGroups[0].months[0]);

      const newCollapsedYears = new Set<number>();
      const newExpandedMonths = new Set<string>();

      for (const yg of yearGroups) {
        if (yg.year !== latestYear) {
          newCollapsedYears.add(yg.year);
        }
      }
      newExpandedMonths.add(latestMonthKey);

      setCollapsedYears(newCollapsedYears);
      setExpandedMonths(newExpandedMonths);
      setHasInitializedState(true);
    }
  }, [yearGroups, hasInitializedState, activeView]);

  // Infinite scroll: load the next page when the sentinel comes into view. The observer only
  // reports transitions, so a page that doesn't push the sentinel out of view doesn't trigger
  // another one by itself. That matters in the timeline: pages land in collapsed months, and
  // re-firing until the screen filled up used to chain through the entire library.
  useEffect(() => {
    const el = observerRef.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries[0].isIntersecting) {
          autoLoadsRef.current = 0;
          fetchPage(false);
        }
      },
      { rootMargin: '600px 0px' }
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, [fetchPage]);

  // Keep filling a tall viewport while pages visibly add content. A gallery page always adds a
  // screenful of tiles; a timeline page only counts if it opened new month sections, and even
  // then at most a few in a row.
  useEffect(() => {
    if (loading || loadingMore || !hasMore || error) return;
    if (activeView === 'timeline' && (!pageAddedGroupsRef.current || autoLoadsRef.current >= 3)) return;
    // Measure once the new content has laid out (grids size themselves after mount and the
    // year sections animate open), or the page looks shorter than it is
    const timer = setTimeout(() => {
      const el = observerRef.current;
      if (el && el.getBoundingClientRect().top < window.innerHeight + 600) {
        autoLoadsRef.current += 1;
        fetchPage(false);
      }
    }, 350);
    return () => clearTimeout(timer);
  }, [galleryItems, timelineGroups, activeView, loading, loadingMore, hasMore, error, fetchPage]);

  // Sticky date for the gallery: the date of the first tile row under the top bar
  useEffect(() => {
    if (activeView !== 'gallery' || galleryItems.length === 0) {
      setActiveDateHeader(null);
      return;
    }
    let frame = 0;
    const update = () => {
      frame = 0;
      const tiles = document.querySelectorAll<HTMLElement>('[data-date]');
      if (tiles.length === 0) return;
      // Tiles are in grid order, so their tops never decrease: binary search instead of
      // measuring every tile on every scroll event
      let lo = 0;
      let hi = tiles.length - 1;
      let found = 0;
      while (lo <= hi) {
        const mid = (lo + hi) >> 1;
        if (tiles[mid].getBoundingClientRect().top <= 140) {
          found = mid;
          lo = mid + 1;
        } else {
          hi = mid - 1;
        }
      }
      setActiveDateHeader(tiles[found].getAttribute('data-date'));
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(update);
    };
    schedule();
    window.addEventListener('scroll', schedule, { passive: true });
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
    };
  }, [activeView, galleryItems]);

  const toggleYear = (year: number) => {
    setCollapsedYears(prev => {
      const next = new Set(prev);
      if (next.has(year)) next.delete(year);
      else next.add(year);
      return next;
    });
  };

  const toggleMonth = (key: string) => {
    setExpandedMonths(prev => {
      const next = new Set(prev);
      if (next.has(key)) next.delete(key);
      else next.add(key);
      return next;
    });
  };

  const isEmpty = !loading && !error && timelineGroups.length === 0 && galleryItems.length === 0;

  return (
    <div className="min-h-screen pb-24">
      <TopBar
        title="Library"
        subtitle={activeDateHeader || (stats?.total_files != null ? `${stats.total_files.toLocaleString()} items · ${stats.total_size_human}` : undefined)}
        showViewControls
        showSourcesButton
      />

      <div className="px-4 lg:px-5 pb-8 mt-2">
        {error && (
          <div className="flex items-center gap-3 mb-6 px-4 py-3 rounded-xl bg-red-500/10 border border-red-500/15" role="alert">
            <AlertCircle size={16} className="text-red-400 shrink-0" />
            <p className="text-[12px] text-red-400 flex-1">Couldn&apos;t load your library: {error}</p>
            <button
              onClick={() => fetchPage(pageRef.current === 0)}
              className="text-[12px] font-medium text-[var(--accent)] hover:underline shrink-0"
            >
              Retry
            </button>
          </div>
        )}

        {isEmpty && (
          <div className="flex flex-col items-center justify-center py-20 text-center">
            <div className="w-14 h-14 rounded-2xl bg-[var(--glass-bg)] flex items-center justify-center mb-4 border border-[var(--glass-border)]">
              <Star size={22} className="text-[var(--text-tertiary)]" />
            </div>
            <p className="text-sm text-[var(--text-secondary)]">No media found</p>
            <p className="text-[11px] text-[var(--text-tertiary)] mt-1">Try adjusting your filters</p>
          </div>
        )}

        {activeView === 'timeline' ? (
          /* ═══ TIMELINE VIEW ═══ */
          <div className="space-y-12">
            {yearGroups.map((yearGroup) => {
              const yearCollapsed = collapsedYears.has(yearGroup.year);

              return (
                <div key={yearGroup.year} className="space-y-6">
                  {/* Year Header */}
                  <div className="flex items-center gap-3 w-full group">
                    <button
                      onClick={() => toggleYear(yearGroup.year)}
                      aria-expanded={!yearCollapsed}
                      className="flex items-center gap-2.5 text-left shrink-0 focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] rounded-lg"
                    >
                      <div
                        className={`w-6 h-6 rounded-full bg-[var(--glass-bg-hover)] flex items-center justify-center
                          group-hover:bg-[var(--glass-bg-active)] transition duration-200
                          ${yearCollapsed ? '' : 'rotate-90'}`}
                      >
                        <ChevronRight size={14} className="text-[var(--text-tertiary)]" />
                      </div>
                      <h1 className="text-3xl font-bold tracking-tight text-[var(--text-primary)]">
                        {yearGroup.year === 0 ? 'Old Photos' : yearGroup.year}
                      </h1>
                    </button>
                    <div className="h-px bg-[var(--glass-border)] flex-1 ml-1" />
                    <span className="text-[11px] font-medium text-[var(--text-tertiary)] shrink-0">
                      {yearGroup.totalItems.toLocaleString()} items
                    </span>
                  </div>

                  {/* Months */}
                  <AnimatePresence>
                    {!yearCollapsed && (
                      <motion.div
                        initial={{ opacity: 0, height: 0 }}
                        animate={{ opacity: 1, height: 'auto' }}
                        exit={{ opacity: 0, height: 0 }}
                        transition={{ duration: 0.25 }}
                        className="pl-2 lg:pl-4 space-y-4 overflow-hidden"
                      >
                        {yearGroup.months.map((group) => {
                          const key = groupKey(group);
                          const monthExpanded = expandedMonths.has(key);

                          return (
                            <section key={key}>
                              <button
                                onClick={() => toggleMonth(key)}
                                aria-expanded={monthExpanded}
                                className="month-header py-1 flex items-center gap-2.5 group/month w-full text-left
                                  focus:outline-none focus-visible:ring-2 focus-visible:ring-[var(--accent)] rounded-lg"
                              >
                                <div className={`transition-transform duration-200 ${monthExpanded ? 'rotate-90' : ''}`}>
                                  <ChevronRight size={14} className="text-[var(--text-tertiary)]" />
                                </div>
                                <h2 className="text-[15px] font-semibold text-[var(--text-primary)]">
                                  {group.year === 0 ? 'Archive' : group.month_name}
                                </h2>
                                <span className="text-[11px] text-[var(--text-tertiary)] font-medium">
                                  · {group.items.length} items
                                </span>
                              </button>

                              <AnimatePresence>
                                {monthExpanded && (
                                  <motion.div
                                    initial={{ opacity: 0 }}
                                    animate={{ opacity: 1 }}
                                    exit={{ opacity: 0 }}
                                    transition={{ duration: 0.2 }}
                                    className="mt-3"
                                  >
                                    <MediaGrid items={group.items} />
                                  </motion.div>
                                )}
                              </AnimatePresence>
                            </section>
                          );
                        })}
                      </motion.div>
                    )}
                  </AnimatePresence>
                </div>
              );
            })}
          </div>
        ) : (
          /* ═══ GALLERY VIEW ═══ */
          <div className="w-full">
            {galleryItems.length > 0 && <MediaGrid items={galleryItems} />}
          </div>
        )}

        {/* Loading Indicator & Infinite Scroll Target */}
        <div ref={observerRef} className="h-20 flex items-center justify-center mt-8">
          {(loading || loadingMore) && (
            <div className="flex gap-2" aria-label="Loading">
              <div className="w-1.5 h-1.5 bg-[var(--accent)] rounded-full animate-bounce [animation-delay:-0.3s]" />
              <div className="w-1.5 h-1.5 bg-[var(--accent)] rounded-full animate-bounce [animation-delay:-0.15s]" />
              <div className="w-1.5 h-1.5 bg-[var(--accent)] rounded-full animate-bounce" />
            </div>
          )}
          {hasMore && !loading && !loadingMore && !error && (timelineGroups.length > 0 || galleryItems.length > 0) && (
            <button onClick={() => { autoLoadsRef.current = 0; fetchPage(false); }} className="glass-pill">
              Load more
            </button>
          )}
          {!hasMore && !loading && (timelineGroups.length > 0 || galleryItems.length > 0) && (
            <p className="text-[12px] text-[var(--text-tertiary)]">You&apos;ve reached the end</p>
          )}
        </div>
      </div>

    </div>
  );
}
