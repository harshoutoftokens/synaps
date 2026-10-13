'use client';

import { useEffect, useRef, useState } from 'react';
import { TopBar } from '@/components/TopBar';
import { browseDirectory, getFinderFileUrl } from '@/lib/api';
import { GlassPanel } from '@/components/glass/GlassPanel';
import { GlassButton } from '@/components/glass/GlassButton';
import { useAppStore, type ViewerEntry } from '@/lib/store';
import {
  Folder, FileText, Image as ImageIcon, Film, File,
  ChevronRight, ArrowLeft, AlertCircle, Download
} from 'lucide-react';

const PAGE_SIZE = 200;

interface FinderFile {
  name: string;
  path: string;
  file_type: string;
  extension: string;
  size_human: string;
  /** Present when the file is in the media catalog; null/absent for anything else. */
  media_id?: string | null;
}

function FileIcon({ type }: { type: string }) {
  const size = 18;
  switch (type) {
    case 'image': return <ImageIcon size={size} className="text-blue-400" />;
    case 'video': return <Film size={size} className="text-purple-400" />;
    case 'document': return <FileText size={size} className="text-amber-400" />;
    default: return <File size={size} className="text-[var(--text-tertiary)]" />;
  }
}

const isPreviewable = (file: FinderFile) => file.file_type === 'image' || file.file_type === 'video';

function toViewerEntry(file: FinderFile): ViewerEntry {
  return file.media_id
    ? { kind: 'media', id: file.media_id }
    : { kind: 'file', path: file.path, name: file.name, fileType: file.file_type, sizeHuman: file.size_human };
}

export default function FinderPage() {
  const [currentPath, setCurrentPath] = useState('');
  const [data, setData] = useState<any>(null);
  const [files, setFiles] = useState<FinderFile[]>([]);
  const [filesPage, setFilesPage] = useState(1);
  const [loading, setLoading] = useState(true);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const openEntries = useAppStore((s) => s.openEntries);
  // Ignore responses for folders we already navigated away from
  const requestRef = useRef(0);

  const navigate = async (path: string) => {
    const request = ++requestRef.current;
    setCurrentPath(path);
    setLoading(true);
    setLoadingMore(false);
    setError(null);
    try {
      const result = await browseDirectory(path, 1, PAGE_SIZE);
      if (request !== requestRef.current) return;
      setData(result);
      setFiles(result.files || []);
      setFilesPage(1);
    } catch (err: any) {
      if (request !== requestRef.current) return;
      console.error('Finder browse error:', err);
      setError(err.message || 'Failed to load directory');
    } finally {
      if (request === requestRef.current) setLoading(false);
    }
  };

  // The API pages files (folders are always complete); fetch the next page on demand
  const loadMoreFiles = async () => {
    if (loadingMore || !data) return;
    const request = requestRef.current;
    setLoadingMore(true);
    try {
      const nextPage = filesPage + 1;
      const result = await browseDirectory(currentPath, nextPage, PAGE_SIZE);
      if (request !== requestRef.current) return;
      setFilesPage(nextPage);
      setFiles((prev) => {
        const seen = new Set(prev.map((f) => f.path));
        return [...prev, ...(result.files || []).filter((f: FinderFile) => !seen.has(f.path))];
      });
    } catch (err: any) {
      if (request !== requestRef.current) return;
      setError(err.message || 'Failed to load more files');
    } finally {
      if (request === requestRef.current) setLoadingMore(false);
    }
  };

  const openFile = (file: FinderFile) => {
    // Step through the folder's photos and videos with ←/→ in the viewer
    const previewable = files.filter(isPreviewable);
    openEntries(previewable.map(toViewerEntry), Math.max(0, previewable.indexOf(file)));
  };

  useEffect(() => {
    navigate('');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const totalFiles: number = data?.total_files ?? files.length;

  return (
    <div className="min-h-screen">
      <TopBar title="Finder" subtitle={currentPath || 'Storage Root'} />

      <div className="px-4 lg:px-6 py-6">
        {/* Breadcrumb */}
        {data?.breadcrumb && (
          <div className="flex items-center gap-1 mb-5 text-xs overflow-x-auto no-scrollbar">
            {data.breadcrumb.map((crumb: any, i: number) => (
              <div key={i} className="flex items-center gap-1 shrink-0">
                {i > 0 && <ChevronRight size={11} className="text-[var(--text-muted)]" />}
                <button
                  onClick={() => navigate(crumb.path)}
                  className={`px-2 py-1 rounded-lg transition-colors
                    ${i === data.breadcrumb.length - 1
                      ? 'text-[var(--text-primary)] font-medium bg-[var(--glass-bg)]'
                      : 'text-[var(--text-tertiary)] hover:text-[var(--text-secondary)] hover:bg-[var(--glass-bg)]'
                    }`}
                >
                  {crumb.name}
                </button>
              </div>
            ))}
          </div>
        )}

        {/* Error state */}
        {error && (
          <div className="flex flex-col items-center justify-center py-20">
            <AlertCircle size={32} className="text-red-400/70 mb-3" />
            <p className="text-sm text-red-400/80 mb-2">{error}</p>
            <button
              onClick={() => navigate(currentPath)}
              className="text-xs text-[var(--accent)] hover:underline"
            >
              Retry
            </button>
          </div>
        )}

        {loading ? (
          <div className="flex justify-center py-20">
            <div className="w-8 h-8 rounded-full border-2 border-[var(--accent)]/20 border-t-[var(--accent)] animate-spin" />
          </div>
        ) : !error && (
          <div>
            {/* Back button */}
            {currentPath && (
              <GlassButton
                variant="ghost"
                onClick={() => {
                  const parent = currentPath.split('/').slice(0, -1).join('/');
                  navigate(parent);
                }}
                className="flex items-center gap-2 mb-5 text-sm"
              >
                <ArrowLeft size={16} /> Back
              </GlassButton>
            )}

            {/* Folders */}
            {data?.folders?.length > 0 && (
              <div className="mb-6">
                <h3 className="section-label mb-3">
                  Folders ({data.total_folders})
                </h3>
                <div className="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6 gap-3">
                  {data.folders.map((folder: any) => (
                    <GlassPanel
                      key={folder.path}
                      as="button"
                      onClick={() => navigate(folder.path)}
                      className="flex flex-col items-center gap-2 p-4 rounded-2xl
                        glass-hover group transition-all duration-200"
                    >
                      <Folder size={32} className="text-[var(--accent)] group-hover:text-[var(--accent-light)] transition-colors" />
                      <span className="text-[11px] font-medium text-[var(--text-secondary)] truncate w-full text-center">
                        {folder.name}
                      </span>
                      <span className="text-[10px] text-[var(--text-tertiary)]">
                        {folder.children_count} items
                      </span>
                    </GlassPanel>
                  ))}
                </div>
              </div>
            )}

            {/* Files */}
            {files.length > 0 && (
              <div>
                <h3 className="section-label mb-3">
                  Files ({totalFiles})
                </h3>
                <div className="space-y-1">
                  {files.map((file) => {
                    const rowClass = `w-full flex items-center gap-3 px-3 py-2.5 rounded-xl text-left
                      hover:bg-[var(--glass-bg-hover)] transition-colors cursor-pointer group`;
                    const rowContent = (
                      <>
                        <FileIcon type={file.file_type} />
                        <div className="flex-1 min-w-0">
                          <p className="text-[13px] text-[var(--text-primary)] truncate">{file.name}</p>
                          <p className="text-[10px] text-[var(--text-tertiary)]">{file.size_human}</p>
                        </div>
                        <span className="text-[10px] text-[var(--text-muted)] uppercase font-medium">{(file.extension || '').replace('.', '')}</span>
                      </>
                    );
                    return isPreviewable(file) ? (
                      <button key={file.path} type="button" onClick={() => openFile(file)} className={rowClass}>
                        {rowContent}
                      </button>
                    ) : (
                      <a key={file.path} href={getFinderFileUrl(file.path)} download={file.name} className={rowClass}>
                        {rowContent}
                        <Download size={13} className="text-[var(--text-muted)] shrink-0" aria-hidden />
                      </a>
                    );
                  })}
                </div>
                {filesPage * PAGE_SIZE < totalFiles && (
                  <div className="flex justify-center mt-4">
                    <button onClick={loadMoreFiles} disabled={loadingMore} className="glass-pill">
                      {loadingMore ? 'Loading…' : `Show more (${(totalFiles - files.length).toLocaleString()} remaining)`}
                    </button>
                  </div>
                )}
              </div>
            )}

            {/* Empty */}
            {(!data?.folders?.length && !files.length) && (
              <div className="flex flex-col items-center justify-center py-20">
                <Folder size={36} className="text-[var(--text-muted)] mb-3" />
                <p className="text-sm text-[var(--text-tertiary)]">Empty folder</p>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
