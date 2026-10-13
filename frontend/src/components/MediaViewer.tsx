'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { motion, AnimatePresence } from 'framer-motion';
import { useAppStore, type ViewerEntry } from '@/lib/store';
import {
  ApiError, getMediaItem, getFileUrl, getFinderFileUrl, getStreamUrl, getThumbnailUrl,
  toggleFavorite, moveToTrash,
} from '@/lib/api';
import {
  X, ChevronLeft, ChevronRight, Star, Trash2, Download,
  ZoomIn, ZoomOut, Info, AlertCircle
} from 'lucide-react';

const toolbarButton = 'p-2 rounded-xl hover:bg-[var(--glass-bg-hover)] transition-colors disabled:opacity-40 disabled:pointer-events-none';
const navButton = 'absolute top-1/2 -translate-y-1/2 z-[5] w-10 h-10 rounded-full flex items-center justify-center bg-black/40 hover:bg-black/60 border border-white/10 transition-colors';

function entryKey(entry: ViewerEntry | undefined) {
  if (!entry) return '';
  return entry.kind === 'media' ? `media:${entry.id}` : `file:${entry.path}`;
}

export function MediaViewer() {
  const viewerOpen = useAppStore((s) => s.viewerOpen);
  const entries = useAppStore((s) => s.viewerEntries);
  const index = useAppStore((s) => s.viewerIndex);
  const setViewerIndex = useAppStore((s) => s.setViewerIndex);
  const openEntries = useAppStore((s) => s.openEntries);
  const closeViewer = useAppStore((s) => s.closeViewer);
  const markAsDeleted = useAppStore((s) => s.markAsDeleted);
  const setFavoriteOverride = useAppStore((s) => s.setFavoriteOverride);

  const entry = viewerOpen ? entries[index] : undefined;
  const currentKey = entryKey(entry);
  const isFile = entry?.kind === 'file';

  // Per-item state is tagged with the entry it belongs to, so after ←/→ nothing from the
  // previous item (details, load error, loaded flag) can render for even a frame.
  const [detail, setDetail] = useState<{ key: string; data: any } | null>(null);
  const [failure, setFailure] = useState<{ key: string; message: string } | null>(null);
  const [fullLoadedKey, setFullLoadedKey] = useState('');
  const [imageErrorKey, setImageErrorKey] = useState('');
  const [retry, setRetry] = useState({ key: '', count: 0 });
  const [showInfo, setShowInfo] = useState(false);
  const [zoom, setZoom] = useState(1);
  const [busy, setBusy] = useState(false);
  const closeButtonRef = useRef<HTMLButtonElement>(null);

  const media = entry?.kind === 'file'
    ? { filename: entry.name, media_type: entry.fileType, file_size_human: entry.sizeHuman, path: entry.path }
    : detail?.key === currentKey ? detail.data : null;
  const loadError = failure?.key === currentKey ? failure.message : null;
  const loading = entry?.kind === 'media' && !media && !loadError;
  const fullLoaded = fullLoadedKey === currentKey;
  const imageError = imageErrorKey === currentKey;
  const retries = retry.key === currentKey ? retry.count : 0;

  // Load details for the current entry, ignoring responses for entries we already left
  useEffect(() => {
    setZoom(1);
    if (!entry || entry.kind !== 'media') return;
    const key = currentKey;
    let cancelled = false;
    getMediaItem(entry.id)
      .then((data) => {
        if (!cancelled) setDetail({ key, data });
      })
      .catch((err) => {
        if (cancelled) return;
        setFailure({
          key,
          message: err instanceof ApiError && err.status === 404
            ? 'This item no longer exists. It may have been moved or deleted.'
            : err?.message || 'Failed to load this item.',
        });
      });
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [currentKey]);

  const hasPrev = index > 0;
  const hasNext = index < entries.length - 1;
  const goPrev = useCallback(() => {
    if (hasPrev) setViewerIndex(index - 1);
  }, [hasPrev, index, setViewerIndex]);
  const goNext = useCallback(() => {
    if (hasNext) setViewerIndex(index + 1);
  }, [hasNext, index, setViewerIndex]);

  useEffect(() => {
    if (!viewerOpen) return;
    const handleKeyDown = (e: KeyboardEvent) => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
      const target = e.target as HTMLElement | null;
      if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) return;
      // Arrow keys seek inside a focused <video>
      const inVideo = target?.tagName === 'VIDEO';
      switch (e.key) {
        case 'Escape':
          if (showInfo) setShowInfo(false);
          else closeViewer();
          break;
        case 'ArrowLeft':
          if (inVideo) return;
          goPrev();
          break;
        case 'ArrowRight':
          if (inVideo) return;
          goNext();
          break;
        case '+':
        case '=':
          setZoom((z) => Math.min(z + 0.25, 5));
          break;
        case '-':
          setZoom((z) => Math.max(z - 0.25, 0.5));
          break;
        case '0':
          setZoom(1);
          break;
        default:
          return;
      }
      e.preventDefault();
    };
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [viewerOpen, showInfo, closeViewer, goPrev, goNext]);

  // Modal behaviour: lock page scroll, move focus in, give it back on close
  useEffect(() => {
    if (!viewerOpen) return;
    const previouslyFocused = document.activeElement as HTMLElement | null;
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    closeButtonRef.current?.focus();
    return () => {
      document.body.style.overflow = previousOverflow;
      previouslyFocused?.focus?.({ preventScroll: true });
      setShowInfo(false);
    };
  }, [viewerOpen]);

  const handleFavorite = async () => {
    if (!media || isFile || busy) return;
    try {
      const result = await toggleFavorite(media.id);
      setDetail((d) => (d && d.data.id === result.id ? { ...d, data: { ...d.data, is_favorite: result.is_favorite } } : d));
      setFavoriteOverride(result.id, result.is_favorite);
    } catch (err: any) {
      alert(`Failed to update favorite: ${err.message || 'Unknown error'}`);
    }
  };

  const handleDelete = async () => {
    if (!entry || entry.kind !== 'media' || busy) return;
    setBusy(true);
    try {
      await moveToTrash(entry.id);
      markAsDeleted(entry.id);
      // Stay in the viewer on the next item, like Photos does
      const remaining = entries.filter((_, i) => i !== index);
      if (remaining.length === 0) closeViewer();
      else openEntries(remaining, Math.min(index, remaining.length - 1));
    } catch (err: any) {
      console.error('Failed to move to trash:', err);
      alert(`Failed to delete: ${err.message || 'Unknown error'}`);
    } finally {
      setBusy(false);
    }
  };

  // Download the original bytes (getFileUrl transcodes HEIC to a downscaled JPEG)
  const downloadUrl = !media
    ? undefined
    : media.path
      ? getFinderFileUrl(media.path)
      : getFileUrl(media.id);
  const thumbSrc = entry?.kind === 'media' ? getThumbnailUrl(entry.id) : undefined;
  const baseImageSrc = !media ? undefined : isFile ? getFinderFileUrl(media.path) : getFileUrl(media.id);
  const imageSrc = baseImageSrc && retries ? `${baseImageSrc}&retry=${retries}` : baseImageSrc;

  // The NAS answers 503 while its HEIC converter is busy (e.g. when stepping through photos
  // quickly): retry a couple of times before settling for the thumbnail
  const handleImageError = (key: string) => {
    if (retries < 2) {
      setTimeout(() => setRetry((r) => ({ key, count: (r.key === key ? r.count : 0) + 1 })), 2500);
    } else {
      setImageErrorKey(key);
    }
  };
  const videoSrc = !media ? undefined : isFile ? getFinderFileUrl(media.path) : getStreamUrl(media.id);

  const renderContent = () => {
    if (loadError) {
      return (
        <div className="flex flex-col items-center gap-3 text-center px-6">
          <AlertCircle size={28} className="text-amber-400" />
          <p className="text-sm text-[var(--text-secondary)]">{loadError}</p>
        </div>
      );
    }
    if (!media) {
      // Metadata still loading: show the (usually cached) grid thumbnail straight away
      return (
        <div className="relative flex items-center justify-center w-full h-full">
          {thumbSrc && (
            <img src={thumbSrc} alt="" className="max-w-full max-h-full object-contain opacity-60" draggable={false} />
          )}
          {loading && (
            <div className="absolute w-10 h-10 rounded-full border-2 border-[var(--accent)]/20 border-t-[var(--accent)] animate-spin" />
          )}
        </div>
      );
    }
    if (media.media_type === 'video') {
      return (
        <video
          key={currentKey}
          src={videoSrc}
          poster={thumbSrc}
          controls
          autoPlay
          playsInline
          className="max-w-full max-h-full object-contain"
          style={{ transform: `scale(${zoom})` }}
        />
      );
    }
    if (media.media_type === 'image') {
      if (imageError) {
        return (
          <div className="relative flex items-center justify-center w-full h-full">
            {thumbSrc ? (
              <img
                src={thumbSrc}
                alt={media.filename}
                className="max-w-full max-h-full object-contain transition-transform duration-200"
                style={{ transform: `scale(${zoom})` }}
                draggable={false}
              />
            ) : (
              <div className="text-[var(--text-tertiary)] text-sm">This browser can&apos;t display this image</div>
            )}
            {/* Only show unsupported banner for non-HEIC formats — HEIC is handled by backend transcoding */}
            {thumbSrc && !media.filename.toLowerCase().endsWith('.heic') && (
              <div
                className="absolute top-4 left-1/2 -translate-x-1/2 px-4 py-2 rounded-full flex items-center gap-2 text-[var(--text-secondary)] text-xs"
                style={{
                  background: 'rgba(15, 12, 30, 0.7)',
                  backdropFilter: 'blur(20px)',
                  WebkitBackdropFilter: 'blur(20px)',
                  border: '1px solid var(--glass-border)',
                }}
              >
                <AlertCircle size={14} className="text-amber-400" />
                Could not load full image. Showing preview.
              </div>
            )}
          </div>
        );
      }
      return (
        <div className="relative flex items-center justify-center w-full h-full">
          {/* Low-res preview until the full image (or the NAS's HEIC transcode) arrives */}
          {thumbSrc && !fullLoaded && (
            <img src={thumbSrc} alt="" className="absolute inset-0 w-full h-full object-contain" style={{ transform: `scale(${zoom})` }} draggable={false} />
          )}
          <img
            key={currentKey}
            src={imageSrc}
            alt={media.filename}
            className={`relative max-w-full max-h-full object-contain transition-[transform,opacity] duration-200 ${fullLoaded ? 'opacity-100' : 'opacity-0'}`}
            style={{ transform: `scale(${zoom})` }}
            draggable={false}
            decoding="async"
            onLoad={() => setFullLoadedKey(currentKey)}
            onError={() => handleImageError(currentKey)}
          />
          {!fullLoaded && (
            <div className="absolute bottom-6 w-6 h-6 rounded-full border-2 border-white/20 border-t-white/70 animate-spin" />
          )}
        </div>
      );
    }
    return (
      <div className="flex flex-col items-center gap-3">
        <div className="text-[var(--text-tertiary)] text-sm">Preview not available</div>
        {downloadUrl && (
          <a href={downloadUrl} download className="glass-pill">
            <Download size={12} /> Download
          </a>
        )}
      </div>
    );
  };

  return (
    <AnimatePresence>
      {viewerOpen && (
        <motion.div
          key="media-viewer"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          // The viewer is always dark: scope the dark tokens so controls stay visible in light mode
          className="dark fixed inset-0 z-[100] flex flex-col"
          role="dialog"
          aria-modal="true"
          aria-label={media?.filename || 'Media viewer'}
          style={{
            background: 'rgba(5, 3, 12, 0.95)',
            backdropFilter: 'blur(20px)',
            WebkitBackdropFilter: 'blur(20px)',
            color: 'var(--text-primary)',
          }}
        >
          {/* Top bar — glass */}
          <motion.div
            initial={{ y: -20, opacity: 0 }}
            animate={{ y: 0, opacity: 1 }}
            className="flex items-center justify-between gap-2 px-4 py-3"
            style={{
              background: 'rgba(15, 12, 30, 0.6)',
              backdropFilter: 'blur(40px) saturate(180%)',
              WebkitBackdropFilter: 'blur(40px) saturate(180%)',
              borderBottom: '1px solid var(--glass-border)',
            }}
          >
            <button ref={closeButtonRef} onClick={closeViewer} className={toolbarButton} aria-label="Close viewer">
              <X size={20} className="text-[var(--text-secondary)]" />
            </button>

            <div className="flex items-center justify-center gap-2 min-w-0 max-w-[40%] text-[13px] text-[var(--text-secondary)] font-medium">
              <span className="truncate">{media?.filename}</span>
              {entries.length > 1 && (
                <span className="shrink-0 text-[11px] text-[var(--text-tertiary)] tabular-nums">
                  {index + 1} / {entries.length}
                </span>
              )}
            </div>

            <div className="flex items-center gap-0.5">
              <button onClick={() => setZoom(z => Math.min(z + 0.25, 5))} className={`${toolbarButton} hidden sm:block`} aria-label="Zoom in">
                <ZoomIn size={17} className="text-[var(--text-tertiary)]" />
              </button>
              <button onClick={() => setZoom(z => Math.max(z - 0.25, 0.5))} className={`${toolbarButton} hidden sm:block`} aria-label="Zoom out">
                <ZoomOut size={17} className="text-[var(--text-tertiary)]" />
              </button>
              {!isFile && (
                <button
                  onClick={handleFavorite}
                  disabled={!media}
                  className={toolbarButton}
                  aria-label={media?.is_favorite ? 'Remove from favorites' : 'Add to favorites'}
                  aria-pressed={!!media?.is_favorite}
                >
                  <Star
                    size={17}
                    className={media?.is_favorite ? 'text-amber-400' : 'text-[var(--text-tertiary)]'}
                    fill={media?.is_favorite ? 'currentColor' : 'none'}
                  />
                </button>
              )}
              <button
                onClick={() => setShowInfo(!showInfo)}
                disabled={!media}
                className={toolbarButton}
                aria-label="Show details"
                aria-pressed={showInfo}
              >
                <Info size={17} className="text-[var(--text-tertiary)]" />
              </button>
              <a
                href={downloadUrl}
                download={media?.filename || true}
                aria-label="Download original"
                aria-disabled={!downloadUrl}
                className={`${toolbarButton} ${downloadUrl ? '' : 'opacity-40 pointer-events-none'}`}
              >
                <Download size={17} className="text-[var(--text-tertiary)]" />
              </a>
              {!isFile && (
                <button
                  onClick={handleDelete}
                  disabled={!media || busy}
                  className="p-2 rounded-xl hover:bg-red-500/10 transition-colors disabled:opacity-40 disabled:pointer-events-none"
                  aria-label="Move to trash"
                >
                  <Trash2 size={17} className="text-red-400/60" />
                </button>
              )}
            </div>
          </motion.div>

          {/* Content */}
          <div className="flex-1 flex items-center justify-center overflow-hidden relative">
            {renderContent()}

            {hasPrev && (
              <button onClick={goPrev} className={`${navButton} left-3`} aria-label="Previous">
                <ChevronLeft size={20} className="text-white/80" />
              </button>
            )}
            {hasNext && (
              <button onClick={goNext} className={`${navButton} right-3`} aria-label="Next">
                <ChevronRight size={20} className="text-white/80" />
              </button>
            )}
          </div>

          {/* Invisible overlay to close info panel when clicking outside */}
          {showInfo && (
            <div
              className="absolute inset-0 z-10"
              onClick={() => setShowInfo(false)}
            />
          )}

          {/* Info panel — glass */}
          <AnimatePresence>
            {showInfo && media && (
              <motion.div
                initial={{ x: 300 }}
                animate={{ x: 0 }}
                exit={{ x: 300 }}
                transition={{ type: 'spring', damping: 25, stiffness: 200 }}
                className="absolute right-0 top-0 bottom-0 w-72 max-w-[85vw] p-5 overflow-y-auto z-20"
                style={{
                  background: 'rgba(15, 12, 30, 0.8)',
                  backdropFilter: 'blur(64px) saturate(200%)',
                  WebkitBackdropFilter: 'blur(64px) saturate(200%)',
                  borderLeft: '1px solid var(--glass-border)',
                }}
              >
                <h3 className="text-[13px] font-semibold text-[var(--text-primary)] mb-4">Details</h3>
                <div className="space-y-3 text-xs">
                  {[
                    ['Filename', media.filename],
                    ['Type', media.media_type],
                    ['Size', media.file_size_human || 'N/A'],
                    ['Dimensions', media.width && media.height ? `${media.width} × ${media.height}` : 'N/A'],
                    ['Date Taken', media.date_taken ? new Date(media.date_taken).toLocaleDateString() : 'N/A'],
                    ['Path', media.path],
                    ['Camera', media.camera_make ? `${media.camera_make} ${media.camera_model || ''}` : 'N/A'],
                  ].map(([label, value]) => (
                    <div key={label}>
                      <div className="text-[var(--text-tertiary)] mb-0.5 text-[11px]">{label}</div>
                      <div className="text-[var(--text-secondary)] break-all">{value}</div>
                    </div>
                  ))}
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </motion.div>
      )}
    </AnimatePresence>
  );
}
