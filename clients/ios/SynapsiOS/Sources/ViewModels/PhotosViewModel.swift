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
    @Published public var columnCount: Int = 5
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedItemIds: Set<String> = []
    @Published public var selectedItemForDetail: SynapsMediaItem? = nil
    @Published public var showSettingsSheet: Bool = false
    @Published public var showActivityLogSheet: Bool = false
    @Published public var visibleDateRangeText: String = ""
    
    // Services
    @ObservedObject private var photoLibrary = PhotoLibraryService.shared
    @ObservedObject private var syncManager = SyncManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    
    private var cancellables = Set<AnyCancellable>()
    private var visibleItemDates: [Int: Date] = [:]
    
    public init() {
        // Forward changes from PhotoLibraryService and SyncManager
        PhotoLibraryService.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.recalculateVisibleDateRange()
            }
            .store(in: &cancellables)
            
        SyncManager.shared.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
    
    public func itemDidAppear(at index: Int, date: Date) {
        visibleItemDates[index] = date
        recalculateVisibleDateRange()
    }
    
    public func itemDidDisappear(at index: Int) {
        visibleItemDates.removeValue(forKey: index)
        recalculateVisibleDateRange()
    }
    
    public func recalculateVisibleDateRange() {
        let dates = Array(visibleItemDates.values)
        if dates.isEmpty {
            let topDates = Array(filteredItems.prefix(15).map { $0.createdAt })
            formatDateRange(from: topDates)
        } else {
            formatDateRange(from: dates)
        }
    }
    
    private func formatDateRange(from dates: [Date]) {
        guard let minDate = dates.min(), let maxDate = dates.max() else {
            self.visibleDateRangeText = ""
            return
        }
        
        let cal = Calendar.current
        let sameDay = cal.isDate(minDate, inSameDayAs: maxDate)
        let sameMonth = cal.isDate(minDate, equalTo: maxDate, toGranularity: .month)
        let sameYear = cal.isDate(minDate, equalTo: maxDate, toGranularity: .year)
        
        if sameDay {
            let df = DateFormatter()
            df.dateFormat = "d MMM yyyy"
            self.visibleDateRangeText = df.string(from: maxDate)
        } else if sameMonth && sameYear {
            let d1 = cal.component(.day, from: minDate)
            let d2 = cal.component(.day, from: maxDate)
            let startDay = min(d1, d2)
            let endDay = max(d1, d2)
            let myf = DateFormatter()
            myf.dateFormat = "MMM yyyy"
            self.visibleDateRangeText = "\(startDay) – \(endDay) \(myf.string(from: maxDate))"
        } else if sameYear {
            let mf1 = DateFormatter()
            mf1.dateFormat = "d MMM"
            let mf2 = DateFormatter()
            mf2.dateFormat = "d MMM yyyy"
            let first = minDate < maxDate ? minDate : maxDate
            let last = minDate < maxDate ? maxDate : minDate
            self.visibleDateRangeText = "\(mf1.string(from: first)) – \(mf2.string(from: last))"
        } else {
            let yf = DateFormatter()
            yf.dateFormat = "MMM yyyy"
            let first = minDate < maxDate ? minDate : maxDate
            let last = minDate < maxDate ? maxDate : minDate
            self.visibleDateRangeText = "\(yf.string(from: first)) – \(yf.string(from: last))"
        }
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
