import { create } from 'zustand';

/** Something the media viewer can show: an indexed media item, or a raw file opened from Finder. */
export type ViewerEntry =
  | { kind: 'media'; id: string }
  | { kind: 'file'; path: string; name: string; fileType: string; sizeHuman?: string };

interface AppState {
  // Theme
  theme: 'light' | 'dark' | 'system';
  setTheme: (theme: 'light' | 'dark' | 'system') => void;

  // Sidebar
  sidebarOpen: boolean;
  toggleSidebar: () => void;
  setSidebarOpen: (open: boolean) => void;

  // Media Viewer — the list it was opened from, so ←/→ can step through it
  viewerOpen: boolean;
  viewerEntries: ViewerEntry[];
  viewerIndex: number;
  openViewer: (mediaId: string, siblingIds?: string[]) => void;
  openEntries: (entries: ViewerEntry[], index: number) => void;
  setViewerIndex: (index: number) => void;
  closeViewer: () => void;

  // Library filter (media type)
  activeFilter: string | null;
  setFilter: (filter: string | null) => void;

  // View mode (timeline vs gallery)
  activeView: 'timeline' | 'gallery';
  setActiveView: (view: 'timeline' | 'gallery') => void;

  // Source filter (sidebar)
  activeSources: Set<string>;
  toggleSource: (source: string) => void;
  clearSources: () => void;

  // Search
  searchQuery: string;
  setSearchQuery: (query: string) => void;

  // Deleted items tracking (hidden from grids until the next refetch)
  deletedMediaIds: Set<string>;
  markAsDeleted: (id: string) => void;

  // Favorite toggles made in the viewer, so grid badges update without a refetch
  favoriteOverrides: Record<string, boolean>;
  setFavoriteOverride: (id: string, isFavorite: boolean) => void;
}

export const useAppStore = create<AppState>((set) => ({
  // Theme
  theme: 'dark',
  setTheme: (theme) => set({ theme }),

  // Sidebar — only affects the mobile drawer (always visible on lg+), so start closed
  sidebarOpen: false,
  toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
  setSidebarOpen: (open) => set({ sidebarOpen: open }),

  // Viewer
  viewerOpen: false,
  viewerEntries: [],
  viewerIndex: 0,
  openViewer: (mediaId, siblingIds) => {
    const ids = siblingIds && siblingIds.includes(mediaId) ? siblingIds : [mediaId];
    set({
      viewerOpen: true,
      viewerEntries: ids.map((id) => ({ kind: 'media' as const, id })),
      viewerIndex: ids.indexOf(mediaId),
    });
  },
  openEntries: (entries, index) =>
    set({ viewerOpen: entries.length > 0, viewerEntries: entries, viewerIndex: index }),
  setViewerIndex: (index) => set({ viewerIndex: index }),
  closeViewer: () => set({ viewerOpen: false, viewerEntries: [], viewerIndex: 0 }),

  // Library filter
  activeFilter: null,
  setFilter: (filter) => set({ activeFilter: filter }),

  // View mode
  activeView: 'timeline',
  setActiveView: (view) => set({ activeView: view }),

  // Source filter
  activeSources: new Set(),
  toggleSource: (source) =>
    set((s) => {
      const next = new Set(s.activeSources);
      if (next.has(source)) next.delete(source);
      else next.add(source);
      return { activeSources: next };
    }),
  clearSources: () => set({ activeSources: new Set() }),

  // Search
  searchQuery: '',
  setSearchQuery: (query) => set({ searchQuery: query }),

  // Deleted
  deletedMediaIds: new Set(),
  markAsDeleted: (id) =>
    set((s) => {
      const newSet = new Set(s.deletedMediaIds);
      newSet.add(id);
      return { deletedMediaIds: newSet };
    }),

  // Favorites
  favoriteOverrides: {},
  setFavoriteOverride: (id, isFavorite) =>
    set((s) => ({ favoriteOverrides: { ...s.favoriteOverrides, [id]: isFavorite } })),
}));
