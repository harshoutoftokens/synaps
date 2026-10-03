import SwiftUI
import Photos
import Combine

@MainActor
public final class PhotosViewModel: ObservableObject {
    public enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All Photos"
        case uncommitted = "Uncommitted"
        case committed = "Committed"
        case videos = "Videos"
        case favorites = "Favorites"
        
        public var id: String { rawValue }
        
        public var iconName: String {
            switch self {
            case .all: return "photo.stack"
            case .uncommitted: return "xmark.circle.fill"
            case .committed: return "checkmark.circle.fill"
            case .videos: return "video"
            case .favorites: return "heart.fill"
            }
        }
    }
    
    public struct DateGroup: Identifiable {
        public let id: String
        public let title: String
        public let subtitle: String
        public let items: [SynapsMediaItem]
    }
    
    // Published UI States
    @Published public var filter: FilterOption = .all
    @Published public var columnCount: Int = 3
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedItemIds: Set<String> = []
    @Published public var selectedItemForDetail: SynapsMediaItem? = nil
    @Published public var showSettingsSheet: Bool = false
    @Published public var showActivityLogSheet: Bool = false
    
    // Services
    @ObservedObject private var photoLibrary = PhotoLibraryService.shared
    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        // Forward changes from PhotoLibraryService and SyncManager
        PhotoLibraryService.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
            
        SyncManager.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    public var rawItems: [SynapsMediaItem] {
        photoLibrary.mediaItems
    }
    
    public var isLoading: Bool {
        photoLibrary.isLoading
    }
    
    public var authorizationStatus: PHAuthorizationStatus {
        photoLibrary.authorizationStatus
    }
    
    public var isSyncing: Bool {
        syncManager.isSyncing
    }
    
    public var syncProgress: Double {
        syncManager.currentProgress
    }
    
    public var syncItemName: String {
        syncManager.currentItemName
    }
    
    public var syncedCount: Int {
        syncManager.syncedCount
    }
    
    public var totalToSyncCount: Int {
        syncManager.totalToSyncCount
    }
    
    public var isConnectedToNAS: Bool {
        syncManager.isConnectedToNAS
    }
    
    public var filteredItems: [SynapsMediaItem] {
        switch filter {
        case .all:
            return rawItems
        case .uncommitted:
            return rawItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }
        case .committed:
            return rawItems.filter { $0.syncStatus == .committed }
        case .videos:
            return rawItems.filter { $0.isVideo }
        case .favorites:
            return rawItems.filter { $0.isFavorite }
        }
    }
    
    public var committedCount: Int {
        rawItems.filter { $0.syncStatus == .committed }.count
    }
    
    public var uncommittedCount: Int {
        rawItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }.count
    }
    
    public var groupedItems: [DateGroup] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        
        let subFormatter = DateFormatter()
        subFormatter.dateFormat = "MMMM yyyy"
        
        var groups: [DateGroup] = []
        let items = filteredItems
        
        // Group by day
        let groupedByDay = Dictionary(grouping: items) { item -> Date in
            calendar.startOfDay(for: item.createdAt)
        }
        
        let sortedDates = groupedByDay.keys.sorted(by: >)
        
        for date in sortedDates {
            let dayItems = groupedByDay[date] ?? []
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else {
                title = dateFormatter.string(from: date)
            }
            
            let subtitle = subFormatter.string(from: date)
            groups.append(DateGroup(
                id: "\(date.timeIntervalSince1970)",
                title: title,
                subtitle: subtitle,
                items: dayItems
            ))
        }
        
        return groups
    }
    
    // MARK: - Actions
    public func requestAccess() {
        Task {
            _ = await photoLibrary.requestAccess()
        }
    }
    
    public func refresh() {
        Task {
            await syncManager.checkNASStatus()
            await photoLibrary.fetchAllMedia()
        }
    }
    
    public func toggleSelection(for item: SynapsMediaItem) {
        if selectedItemIds.contains(item.id) {
            selectedItemIds.remove(item.id)
            if selectedItemIds.isEmpty && isSelectionMode {
                // Keep selection mode open or close if desired
            }
        } else {
            selectedItemIds.insert(item.id)
            if !isSelectionMode {
                isSelectionMode = true
            }
        }
    }
    
    public func selectAll() {
        selectedItemIds = Set(filteredItems.map { $0.id })
    }
    
    public func deselectAll() {
        selectedItemIds.removeAll()
    }
    
    public func exitSelectionMode() {
        isSelectionMode = false
        selectedItemIds.removeAll()
    }
    
    public func syncSingleItem(_ item: SynapsMediaItem) {
        syncManager.syncItems([item])
    }
    
    public func syncSelectedItems() {
        let itemsToSync = rawItems.filter { selectedItemIds.contains($0.id) }
        guard !itemsToSync.isEmpty else { return }
        syncManager.syncItems(itemsToSync)
        exitSelectionMode()
    }
    
    public func syncAllUncommitted() {
        let uncommitted = rawItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }
        guard !uncommitted.isEmpty else { return }
        syncManager.syncItems(uncommitted)
    }
    
    public func cancelSync() {
        syncManager.cancelSync()
    }
}
