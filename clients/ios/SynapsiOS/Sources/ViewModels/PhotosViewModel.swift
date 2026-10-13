import SwiftUI
import Photos
import Combine

/// One instance is shared by all tabs (injected as an environment object by MainTabView), so the
/// library is enumerated and filtered once instead of once per tab.
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
    @Published public var filter: FilterOption = .all {
        didSet { if filter != oldValue { recomputeFiltered() } }
    }
    @Published public var columnCount: Int = 5
    @Published public var isSelectionMode: Bool = false
    @Published public var selectedItemIds: Set<String> = []
    @Published public var visibleDateRangeText: String = ""
    
    // Derived library state, recomputed only when the library or the filter changes (not on
    // every SwiftUI body evaluation: these used to be computed properties filtering every asset).
    @Published public private(set) var rawItems: [SynapsMediaItem] = []
    @Published public private(set) var filteredItems: [SynapsMediaItem] = []
    /// Items not yet fully on the NAS (uncommitted, failed, or currently syncing).
    @Published public private(set) var pendingItems: [SynapsMediaItem] = []
    @Published public private(set) var committedCount: Int = 0
    @Published public private(set) var uncommittedCount: Int = 0
    @Published public private(set) var pendingBytes: Int64 = 0
    
    // Forwarded service state (changes rarely; progress ticks are observed by SyncProgressBanner only).
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isIndexing: Bool = false
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var isConnectedToNAS: Bool = false
    @Published public private(set) var syncStatusMessage: String?
    
    /// Pixel size the grid requests thumbnails at; preheating must use the same size.
    public var thumbnailPixelSize: CGSize = .zero {
        didSet {
            if thumbnailPixelSize != oldValue {
                PhotoLibraryService.shared.stopCachingAll()
                preheatedIds.removeAll()
            }
        }
    }
    
    private let library = PhotoLibraryService.shared
    private var cancellables = Set<AnyCancellable>()
    private var filteredIndexById: [String: Int] = [:]
    private var visibleIds: Set<String> = []
    private var visibleUpdateScheduled = false
    private var preheatedIds: Set<String> = []
    private var didInitialLoad = false
    
    public init() {
        library.$mediaItems
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] items in
                self?.apply(items)
            }
            .store(in: &cancellables)
        library.$isLoading.removeDuplicates().assign(to: &$isLoading)
        library.$isIndexing.removeDuplicates().assign(to: &$isIndexing)
        library.$authorizationStatus.removeDuplicates().assign(to: &$authorizationStatus)
        SyncManager.shared.$isSyncing.removeDuplicates().assign(to: &$isSyncing)
        SyncManager.shared.$isConnectedToNAS.removeDuplicates().assign(to: &$isConnectedToNAS)
        SyncManager.shared.$statusMessage.removeDuplicates().assign(to: &$syncStatusMessage)
    }
    
    // MARK: - Derived state
    
    private func apply(_ items: [SynapsMediaItem]) {
        rawItems = items
        var pending: [SynapsMediaItem] = []
        var committed = 0
        var uncommitted = 0
        var bytes: Int64 = 0
        for item in items {
            switch item.syncStatus {
            case .committed:
                committed += 1
            case .uncommitted, .failed:
                uncommitted += 1
                bytes += item.pendingBytes
                pending.append(item)
            case .syncing:
                bytes += item.pendingBytes
                pending.append(item)
            }
        }
        pendingItems = pending
        committedCount = committed
        uncommittedCount = uncommitted
        pendingBytes = bytes
        recomputeFiltered()
    }
    
    private func recomputeFiltered() {
        let items: [SynapsMediaItem]
        switch filter {
        case .all:
            items = rawItems
        case .uncommitted:
            items = pendingItems
        case .committed:
            items = rawItems.filter { $0.syncStatus == .committed }
        case .videos:
            items = rawItems.filter { $0.isVideo }
        case .favorites:
            items = rawItems.filter { $0.isFavorite }
        }
        filteredItems = items
        filteredIndexById = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        scheduleVisibleUpdate()
    }
    
    // MARK: - Visible range: date header + thumbnail preheating
    
    public func itemDidAppear(_ id: String) {
        visibleIds.insert(id)
        scheduleVisibleUpdate()
    }
    
    public func itemDidDisappear(_ id: String) {
        visibleIds.remove(id)
        scheduleVisibleUpdate()
    }
    
    /// Coalesces the per-cell appear/disappear storm while scrolling into one update per ~0.1 s,
    /// and publishes the header text only when it actually changes (each publish re-renders the grid).
    private func scheduleVisibleUpdate() {
        guard !visibleUpdateScheduled else { return }
        visibleUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            MainActor.assumeIsolated {
                self?.performVisibleUpdate()
            }
        }
    }
    
    private func performVisibleUpdate() {
        visibleUpdateScheduled = false
        let indices = visibleIds.compactMap { filteredIndexById[$0] }.filter { $0 < filteredItems.count }
        let dates = indices.isEmpty
            ? filteredItems.prefix(15).map { $0.createdAt }
            : indices.map { filteredItems[$0].createdAt }
        let text = Self.formatDateRange(dates)
        if text != visibleDateRangeText {
            visibleDateRangeText = text
        }
        updatePreheat(visibleIndices: indices)
    }
    
    private func updatePreheat(visibleIndices: [Int]) {
        guard thumbnailPixelSize != .zero, let low = visibleIndices.min(), let high = visibleIndices.max() else { return }
        let margin = max(high - low + 1, columnCount * 6)
        let start = max(0, low - margin)
        let end = min(filteredItems.count - 1, high + margin)
        guard start <= end else { return }
        let wanted = Set(filteredItems[start...end].map { $0.id })
        let added = wanted.subtracting(preheatedIds)
        let removed = preheatedIds.subtracting(wanted)
        if !added.isEmpty {
            library.startCaching(ids: Array(added), targetSize: thumbnailPixelSize)
        }
        if !removed.isEmpty {
            library.stopCaching(ids: Array(removed), targetSize: thumbnailPixelSize)
        }
        preheatedIds = wanted
    }
    
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f
    }()
    private static let monthYearFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM yyyy"
        return f
    }()
    private static let dayMonthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
    
    static func formatDateRange(_ dates: [Date]) -> String {
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let cal = Calendar.current
        if cal.isDate(first, inSameDayAs: last) {
            return dayFormatter.string(from: last)
        }
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            let d1 = cal.component(.day, from: first)
            let d2 = cal.component(.day, from: last)
            return "\(d1) – \(d2) \(monthYearFormatter.string(from: last))"
        }
        if cal.isDate(first, equalTo: last, toGranularity: .year) {
            return "\(dayMonthFormatter.string(from: first)) – \(dayFormatter.string(from: last))"
        }
        return "\(monthYearFormatter.string(from: first)) – \(monthYearFormatter.string(from: last))"
    }
    
    public var groupedItems: [DateGroup] {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEEE, MMMM d, yyyy"
        
        let subFormatter = DateFormatter()
        subFormatter.dateFormat = "MMMM yyyy"
        
        var groups: [DateGroup] = []
        let groupedByDay = Dictionary(grouping: filteredItems) { item -> Date in
            calendar.startOfDay(for: item.createdAt)
        }
        
        for date in groupedByDay.keys.sorted(by: >) {
            let dayItems = groupedByDay[date] ?? []
            let title: String
            if calendar.isDateInToday(date) {
                title = "Today"
            } else if calendar.isDateInYesterday(date) {
                title = "Yesterday"
            } else {
                title = dateFormatter.string(from: date)
            }
            groups.append(DateGroup(
                id: "\(date.timeIntervalSince1970)",
                title: title,
                subtitle: subFormatter.string(from: date),
                items: dayItems
            ))
        }
        return groups
    }
    
    // MARK: - Actions
    
    /// First load when the UI appears (later updates come from the PhotoKit change observer).
    public func initialLoad() async {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        library.refreshAuthorizationStatus()
        if library.isAuthorized {
            await library.ensureLoaded()
        }
    }
    
    public func requestAccess() {
        Task {
            _ = await library.requestAccess()
        }
    }
    
    public func refresh() {
        Task {
            await refreshAsync()
        }
    }
    
    /// Awaitable variant for `.refreshable` so the spinner stays until the reload finishes.
    public func refreshAsync() async {
        async let nas: Void = SyncManager.shared.checkNASStatus()
        await library.fetchAllMedia()
        await nas
    }
    
    public func toggleSelection(for item: SynapsMediaItem) {
        if selectedItemIds.contains(item.id) {
            selectedItemIds.remove(item.id)
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
        SyncManager.shared.syncItems([item])
    }
    
    public func syncSelectedItems() {
        let itemsToSync = rawItems.filter { selectedItemIds.contains($0.id) && $0.syncStatus != .committed }
        exitSelectionMode()
        guard !itemsToSync.isEmpty else { return }
        SyncManager.shared.syncItems(itemsToSync)
    }
    
    public func syncAllUncommitted() {
        let uncommitted = pendingItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }
        guard !uncommitted.isEmpty else { return }
        SyncManager.shared.syncItems(uncommitted)
    }
    
    public func cancelSync() {
        SyncManager.shared.cancelSync()
    }
}
