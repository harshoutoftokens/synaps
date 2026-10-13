'use client';

import { getThumbnailUrl } from '@/lib/api';
import { useAppStore } from '@/lib/store';
import { Play, Star } from 'lucide-react';
import { memo, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react';

export interface MediaItem {
  id: string;
  filename: string;
  media_type: string;
  extension: string;
  is_favorite: boolean;
  date_taken: string | null;
  has_thumbnail?: boolean;
  thumbnail_url: string;
  file_url: string;
  stream_url?: string;
  duration?: number;
  date_string?: string;
}

interface MediaGridProps {
  items: MediaItem[];
}

const GAP = 3;

// Same breakpoints / minimum tile sizes as the previous CSS `repeat(auto-fill, minmax(..))` grid
function minTileSize(viewportWidth: number) {
  if (viewportWidth >= 1280) return 180;
  if (viewportWidth >= 1024) return 170;
  if (viewportWidth >= 768) return 160;
  if (viewportWidth >= 640) return 150;
  return 140;
}

// Thumbnails that aren't generated yet come back as an SVG placeholder while the NAS queues
// them. Re-check with backoff, then give up: files that can't be thumbnailed would otherwise be
// re-queued (and re-fail, e.g. a 25 s ffmpeg timeout) every few seconds while the page is open.
const THUMB_POLL_DELAYS = [2000, 3000, 5000, 8000, 13000, 21000];
// ±20% so a screenful of tiles mounted together doesn't poll in lockstep
const jitter = (ms: number) => ms * (0.8 + Math.random() * 0.4);

const useIsoLayoutEffect = typeof window === 'undefined' ? useEffect : useLayoutEffect;

interface MediaThumbnailProps {
  item: MediaItem;
  top: number;
  left: number;
  size: number;
  onOpen: (id: string) => void;
}

const MediaThumbnail = memo(function MediaThumbnail({ item, top, left, size, onOpen }: MediaThumbnailProps) {
  const [loaded, setLoaded] = useState(false);
  const [error, setError] = useState(false);
  const [version, setVersion] = useState(0);
  const favoriteOverride = useAppStore((s) => s.favoriteOverrides[item.id]);
  const isFavorite = favoriteOverride ?? item.is_favorite;
  const thumbUrl = getThumbnailUrl(item.id);
  const src = version ? `${thumbUrl}?t=${version}` : thumbUrl;

  // Poll for the thumbnail if it wasn't ready when we fetched the list. Tiles only exist while
  // near the viewport (the grid is windowed) and polling waits for the placeholder to load.
  useEffect(() => {
    if (item.has_thumbnail || !loaded || error) return;
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout>;
    let attempt = 0;

    const check = async () => {
      try {
        const res = await fetch(thumbUrl, { method: 'HEAD' });
        if (cancelled) return;
        const contentType = res.headers.get('content-type') || '';
        if (res.ok && !contentType.includes('svg')) {
          // Ready! Bust the cache to load the real WebP thumbnail
          setVersion(Date.now());
          return;
        }
        if (res.status >= 400 && res.status < 500) return; // gone or unauthorized: stop
      } catch {
        if (cancelled) return;
      }
      attempt += 1;
      if (attempt < THUMB_POLL_DELAYS.length) timer = setTimeout(check, jitter(THUMB_POLL_DELAYS[attempt]));
    };

    timer = setTimeout(check, jitter(THUMB_POLL_DELAYS[0]));
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [item.has_thumbnail, loaded, error, thumbUrl]);

  return (
    <button
      type="button"
      className="media-thumb group"
      style={{ top, left, width: size, height: size }}
      onClick={() => onOpen(item.id)}
      data-date={item.date_string}
      aria-label={item.filename}
    >
      {/* Skeleton */}
      {!loaded && !error && (
        <div className="absolute inset-0 skeleton" />
      )}

      {/* Thumbnail image */}
      <img
        src={src}
        alt=""
        loading="lazy"
        decoding="async"
        draggable={false}
        onLoad={() => setLoaded(true)}
        onError={() => { setError(true); setLoaded(true); }}
        className={loaded && !error ? 'opacity-100' : 'opacity-0'}
      />

      {/* Error fallback */}
      {error && (
        <div className="absolute inset-0 flex items-center justify-center bg-[var(--glass-bg)]">
          <span className="text-[10px] text-[var(--text-tertiary)] uppercase font-medium">{item.extension.replace('.', '')}</span>
        </div>
      )}

      {/* Video duration badge */}
      {item.media_type === 'video' && (
        <div className="video-duration">
          <Play size={8} fill="currentColor" />
          {item.duration ? formatDuration(item.duration) : ''}
        </div>
      )}

      {/* Video play overlay on hover */}
      {item.media_type === 'video' && (
        <div className="video-overlay">
          <div className="w-10 h-10 rounded-full bg-black/50 backdrop-blur-md flex items-center justify-center border border-white/10">
            <Play size={16} className="text-white ml-0.5" fill="currentColor" />
          </div>
        </div>
      )}

      {/* Favorite badge */}
      {isFavorite && (
        <div className="absolute top-1.5 right-1.5">
          <Star size={12} className="text-amber-400 drop-shadow-lg" fill="currentColor" />
        </div>
      )}

      {/* Hover info overlay */}
      <div className="absolute inset-x-0 bottom-0 h-10 bg-gradient-to-t from-black/50 to-transparent
        opacity-0 group-hover:opacity-100 transition-opacity duration-200">
        <span className="absolute bottom-1.5 left-2 text-[9px] text-white/80 truncate max-w-[90%] font-medium">
          {item.filename}
        </span>
      </div>
    </button>
  );
});

function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${m}:${s.toString().padStart(2, '0')}`;
}

/**
 * Windowed grid: only rows within about one screen of the viewport are mounted, so a library
 * scrolled through thousands of items keeps a few hundred DOM nodes instead of tens of thousands.
 */
export const MediaGrid = memo(function MediaGrid({ items }: MediaGridProps) {
  const deletedIds = useAppStore((s) => s.deletedMediaIds);
  const openViewer = useAppStore((s) => s.openViewer);
  const visibleItems = useMemo(
    () => (deletedIds.size > 0 ? items.filter((i) => !deletedIds.has(i.id)) : items),
    [items, deletedIds]
  );
  const itemsRef = useRef(visibleItems);
  itemsRef.current = visibleItems;
  const hasItems = visibleItems.length > 0;

  const containerRef = useRef<HTMLDivElement>(null);
  const [layout, setLayout] = useState({ cols: 0, size: 0 });
  const [rows, setRows] = useState({ first: 0, last: -1 });

  // Column count and tile size from the container width
  useIsoLayoutEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const measure = () => {
      const width = el.clientWidth;
      if (!width) return;
      const cols = Math.max(1, Math.floor((width + GAP) / (minTileSize(window.innerWidth) + GAP)));
      const size = (width - GAP * (cols - 1)) / cols;
      setLayout((prev) => (prev.cols === cols && Math.abs(prev.size - size) < 0.5 ? prev : { cols, size }));
    };
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(el);
    return () => observer.disconnect();
  }, [hasItems]);

  const rowHeight = layout.size + GAP;
  const rowCount = layout.cols ? Math.ceil(visibleItems.length / layout.cols) : 0;

  // Rows intersecting the viewport, plus one screen of overscan on each side
  useIsoLayoutEffect(() => {
    const el = containerRef.current;
    if (!el || rowCount === 0) return;
    let frame = 0;
    const update = () => {
      frame = 0;
      const top = el.getBoundingClientRect().top;
      const overscan = window.innerHeight;
      const first = Math.max(0, Math.floor((-top - overscan) / rowHeight));
      const last = Math.min(rowCount - 1, Math.floor((window.innerHeight - top + overscan) / rowHeight));
      setRows((prev) => (prev.first === first && prev.last === last ? prev : { first, last }));
    };
    const schedule = () => {
      if (!frame) frame = requestAnimationFrame(update);
    };
    update();
    window.addEventListener('scroll', schedule, { passive: true });
    window.addEventListener('resize', schedule);
    // Content above can move without a scroll event (months expanding, pages appended)
    const observer = new ResizeObserver(schedule);
    observer.observe(document.body);
    return () => {
      cancelAnimationFrame(frame);
      window.removeEventListener('scroll', schedule);
      window.removeEventListener('resize', schedule);
      observer.disconnect();
    };
  }, [rowCount, rowHeight]);

  const handleOpen = useCallback(
    (id: string) => openViewer(id, itemsRef.current.map((i) => i.id)),
    [openViewer]
  );

  if (!hasItems) {
    return (
      <div className="flex flex-col items-center justify-center py-20 text-center">
        <div className="w-14 h-14 rounded-2xl bg-[var(--glass-bg)] flex items-center justify-center mb-4 border border-[var(--glass-border)]">
          <Star size={22} className="text-[var(--text-tertiary)]" />
        </div>
        <p className="text-sm text-[var(--text-secondary)]">No media found</p>
        <p className="text-[11px] text-[var(--text-tertiary)] mt-1">Try adjusting your filters</p>
      </div>
    );
  }

  const { cols, size } = layout;
  const start = cols ? rows.first * cols : 0;
  const end = cols ? Math.min(visibleItems.length, (rows.last + 1) * cols) : 0;

  return (
    <div
      ref={containerRef}
      className="media-grid"
      style={{ height: rowCount ? rowCount * rowHeight - GAP : 0 }}
    >
      {visibleItems.slice(start, end).map((item, k) => {
        const index = start + k;
        return (
          <MediaThumbnail
            key={item.id}
            item={item}
            top={Math.floor(index / cols) * rowHeight}
            left={(index % cols) * (size + GAP)}
            size={size}
            onOpen={handleOpen}
          />
        );
      })}
    </div>
  );
});
