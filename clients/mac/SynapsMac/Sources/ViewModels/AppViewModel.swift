import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedSidebarItem: SidebarItem?
    @Published public var fileItems: [SynapsFileItem] = [] {
        didSet { filteredItemsCache = nil }
    }
    @Published public var isLoading: Bool = false
    @Published public var isSyncing: Bool = false
    @Published public var syncProgress: Double = 0.0
    @Published public var syncSpeedMBs: Double = 0.0
    @Published public var syncStatusMessage: String = "Ready"
    @Published public var nasOnline: Bool = false
    @Published public var isCheckingNAS: Bool = false
    @Published public var nasBaseUrl: String = NASClient.shared.getBaseUrl()
    @Published public var searchQuery: String = "" {
        didSet { filteredItemsCache = nil }
    }
    @Published public var filterSelection: FilterOption = .all {
        didSet { filteredItemsCache = nil }
    }
    @Published public var sortField: SortField = .dateCreated {
        didSet { filteredItemsCache = nil }
    }
    @Published public var sortAscending: Bool = false {
        didSet { filteredItemsCache = nil }
    }
    @Published public var selectedItemIds: Set<String> = []
    @Published public var recentActivities: [SyncActivityItem] = []
    @Published public var showActivityLog: Bool = false
    @Published public var collapsedKinds: Set<String> = []
    /// The NAS answered 401: SYNAPS_API_TOKEN is set there and our token is missing or wrong.
    @Published public var nasAuthFailed: Bool = false
    /// Another address where a Synaps backend answered while the configured NAS is offline.
    /// Only ever suggested: switching requires the user's confirmation.
    @Published public var discoveredNASUrl: String? = nil
    /// Outcome of the last finished sync, shown in the status bar until the next navigation.
    @Published public var lastSyncSummary: String? = nil
    /// Download status for the Home Cloud view.
    @Published public var nasTransferMessage: String? = nil
    
    /// Sidebar hint shown while `nasAuthFailed` is set.
    public var nasAuthMessage: String {
        return "API token missing or wrong · open Settings"
    }
    
    public var isPicturesSection: Bool {
        selectedSidebarItem?.id == "section_pictures" || selectedSidebarItem?.isPhone == true
    }
    
    public var isNASSection: Bool {
        selectedSidebarItem?.isNAS == true
    }
    
    @Published public var currentNASRelativePath: String = ""
    
    /// User-friendly breadcrumb/path for the bottom bar
    public var currentDirectoryDisplay: String {
        if isPicturesSection {
            return "iPhone"
        }
        if isNASSection {
            if currentNASRelativePath.isEmpty {
                return "Home Cloud"
            }
            return "Home Cloud / " + currentNASRelativePath.replacingOccurrences(of: "/", with: " / ")
        }
        let home = NSHomeDirectory()
        if currentFolderPath.hasPrefix(home) {
            let rel = currentFolderPath.replacingOccurrences(of: home, with: "~")
            return rel.replacingOccurrences(of: "/", with: " / ")
        }
        return currentFolderPath.isEmpty ? (selectedSidebarItem?.title ?? "Home") : currentFolderPath.replacingOccurrences(of: "/", with: " / ")
    }
    
    /// Parses NAS timestamps: ISO-8601 with or without fractional seconds and with or without a
    /// timezone. Naive values (the backend's `datetime.isoformat()` of NAS local time) are read in
    /// the Mac's time zone. Returns nil instead of failing for anything unparseable.
    nonisolated public static func parseDate(_ string: String?) -> Date? {
        return NASDateParser.parse(string)
    }
    
    public enum SortField: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateModified = "Date Modified"
        case dateCreated = "Date Created"
        case size = "Size"
        case kind = "Kind"
        
        public var id: String { rawValue }
    }
    
    public enum FileKindGroup: String, CaseIterable, Identifiable {
        case folders = "Folders"
        case images = "Images"
        case videos = "Videos"
        case documents = "Documents"
        case audio = "Audio"
        case archives = "Archives"
        case code = "Developer"
        case other = "Other"
        
        public var id: String { rawValue }
        
        public static func kind(for item: SynapsFileItem) -> FileKindGroup {
            if item.isDirectory { return .folders }
            let ext = (item.filename as NSString).pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "tiff", "bmp", "svg", "raw", "cr2", "nef", "ico", "icns":
                return .images
            case "mp4", "mov", "m4v", "mkv", "avi", "wmv", "flv", "webm", "3gp":
                return .videos
            case "pdf", "doc", "docx", "txt", "rtf", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "keynote", "csv", "md", "markdown":
                return .documents
            case "mp3", "wav", "m4a", "aac", "flac", "aiff", "ogg", "wma", "alac":
                return .audio
            case "zip", "tar", "gz", "tgz", "bz2", "7z", "rar", "dmg", "pkg", "iso":
                return .archives
            case "swift", "py", "js", "ts", "jsx", "tsx", "html", "css", "json", "xml", "yaml", "yml", "sh", "c", "cpp", "h", "rs", "go", "sql", "java", "kt", "rb", "php":
                return .code
            default:
                return .other
            }
        }
    }
    
    public struct FileGroup: Identifiable {
        public let kind: FileKindGroup
        public let items: [SynapsFileItem]
        public var id: String { kind.rawValue }
    }
    
    public func toggleKindCollapsed(_ kind: String) {
        if collapsedKinds.contains(kind) {
            collapsedKinds.remove(kind)
        } else {
            collapsedKinds.insert(kind)
        }
    }
    
    public func isKindCollapsed(_ kind: String) -> Bool {
        return collapsedKinds.contains(kind)
    }
    
    public var groupedItemsByKind: [FileGroup] {
        let allFiltered = filteredItems
        var groups: [FileGroup] = []
        let kinds = sortAscending ? FileKindGroup.allCases : FileKindGroup.allCases.reversed()
        for kind in kinds {
            let matching = allFiltered.filter { FileKindGroup.kind(for: $0) == kind }
            if !matching.isEmpty {
                groups.append(FileGroup(kind: kind, items: matching))
            }
        }
        return groups
    }
    
    public enum FilterOption: String, CaseIterable, Identifiable {
        case all = "All Files"
        case uncommitted = "🔴 Uncommitted Only"
        case committed = "🟢 Committed Only"
        
        public var id: String { rawValue }
    }
    
    private let scanner = LocalFileScanner.shared
    private let nasClient = NASClient.shared
    private let cacheStore = LocalCacheStore.shared
    private let reconciliationEngine = NASReconciliationEngine.shared
    private let syncEngine = SyncEngine()
    public let phoneManager = iPhoneManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    private var nasRecoveryTimer: Timer?
    
    /// Bumped on every navigation so a slow scan, browse or reconciliation of a folder the user has
    /// already left can never overwrite what is on screen now.
    private var loadGeneration = 0
    private var loadTask: Task<Void, Never>?
    private var healthCheckTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    /// Paths in the running sync; reconciliation results must not overwrite their live status.
    private var activeSyncPaths = Set<String>()
    /// When files of the folder on screen were committed by a sync, so a reconciliation that
    /// started earlier can't flip them back to uncommitted.
    private var committedAt: [String: Date] = [:]
    /// `filteredItems` is read many times per render; recomputed only when an input changes.
    private var filteredItemsCache: [SynapsFileItem]?
    
    public init() {
        setupPhoneObserver()
        setupScannerObserver()
        setupSelectionNotifications()
        setupLifecycleObservers()
        startNASRecoveryTimer()
        // Show the folder right away; it is reconciled as soon as the NAS answers.
        loadDefaultFolder()
        Task {
            await checkNASStatus()
        }
    }
    
    private func setupLifecycleObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkNASStatus()
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: SynapsConfig.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let config = note.object as? SynapsConfig else { return }
            Task { @MainActor [weak self] in
                self?.applySettings(config)
            }
        }
        
        NotificationCenter.default.addObserver(
            forName: NASClient.unauthorizedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.markAuthFailed()
            }
        }
    }
    
    /// Flags the 401 state; the activity log gets one entry per occurrence, not one per request.
    private func markAuthFailed() {
        guard !nasAuthFailed else { return }
        nasAuthFailed = true
        cacheStore.logActivity(
            eventType: .syncFailed,
            details: "Home Cloud answered 401: API token missing or wrong. Check Synaps Settings."
        )
        loadRecentActivities()
    }
    
    private func startNASRecoveryTimer() {
        nasRecoveryTimer = Timer.scheduledTimer(withTimeInterval: 45.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, !self.nasOnline else { return }
                await self.checkNASStatus()
            }
        }
    }
    
    private func setupSelectionNotifications() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("ClearSelectionNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.clearSelection()
            }
        }
    }
    
    private func setupScannerObserver() {
        scanner.onItemsHashed = { [weak self] hashedItems in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let generation = self.loadGeneration
                
                // Hashing of a folder the user already left may still report; only apply items on screen.
                var indexByPath: [String: Int] = [:]
                for (i, item) in self.fileItems.enumerated() {
                    indexByPath[item.originalPath] = i
                }
                let relevant = hashedItems.filter { indexByPath[$0.originalPath] != nil }
                guard !relevant.isEmpty else { return }
                
                var items = self.fileItems
                for hashed in relevant {
                    guard let idx = indexByPath[hashed.originalPath], items[idx].syncStatus != .syncing else { continue }
                    items[idx].sha256 = hashed.sha256
                    if hashed.syncStatus == .committed {
                        items[idx].syncStatus = .committed
                    }
                }
                self.fileItems = items
                
                if self.nasOnline {
                    let sourceId = self.selectedSidebarItem?.sourceId ?? "mac_harsh"
                    let startedAt = Date()
                    let reconciled = await self.reconciliationEngine.reconcileHashedItems(
                        hashedItems: relevant,
                        currentFileItems: self.fileItems,
                        sourceId: sourceId
                    )
                    self.mergeReconciled(reconciled, generation: generation, startedAt: startedAt)
                    self.loadRecentActivities()
                }
            }
        }
    }
    
    private func setupPhoneObserver() {
        phoneManager.$connectedDevice
            .receive(on: DispatchQueue.main)
            .sink { [weak self] dev in
                guard let self = self else { return }
                self.objectWillChange.send()
                if dev == nil && self.isPicturesSection {
                    self.fileItems = []
                    self.selectedItemIds.removeAll()
                }
            }
            .store(in: &cancellables)
            
        phoneManager.$phoneMediaItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phoneItems in
                guard let self = self else { return }
                if self.isPicturesSection {
                    self.fileItems = phoneItems
                }
            }
            .store(in: &cancellables)
            
        phoneManager.$isDeviceLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] locked in
                guard let self = self else { return }
                self.objectWillChange.send()
                if locked && self.isPicturesSection {
                    self.fileItems = []
                    self.selectedItemIds.removeAll()
                }
            }
            .store(in: &cancellables)
            
        $selectedItemIds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in
                guard let self = self else { return }
                let urls = self.filteredItems
                    .filter { ids.contains($0.id) && !$0.originalPath.hasPrefix("iPhone://") && !$0.originalPath.hasPrefix("nas://") }
                    .compactMap { URL(fileURLWithPath: $0.originalPath) }
                QuickLookCoordinator.shared.updatePreviewItems(urls)
            }
            .store(in: &cancellables)
    }
    
    public var uncommittedItems: [SynapsFileItem] {
        return fileItems.filter { $0.syncStatus == .uncommitted }
    }
    
    public var uncommittedCount: Int {
        return uncommittedItems.count
    }
    
    public var totalUncommittedSizeFormatted: String {
        let total = uncommittedItems.reduce(0) { $0 + $1.fileSize }
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: total)
    }
    
    public var filteredItems: [SynapsFileItem] {
        if let cached = filteredItemsCache {
            return cached
        }
        let computed = computeFilteredItems()
        filteredItemsCache = computed
        return computed
    }
    
    private func computeFilteredItems() -> [SynapsFileItem] {
        var items = fileItems
        
        switch filterSelection {
        case .all:
            break
        case .uncommitted:
            items = items.filter { $0.syncStatus == .uncommitted }
        case .committed:
            items = items.filter { $0.syncStatus == .committed }
        }
        
        if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchQuery.lowercased()
            items = items.filter { $0.filename.lowercased().contains(q) }
        }
        
        items.sort { a, b in
            let comparison: ComparisonResult
            switch sortField {
            case .name:
                comparison = a.filename.localizedStandardCompare(b.filename)
            case .dateModified:
                comparison = a.modifiedAt.compare(b.modifiedAt)
            case .dateCreated:
                comparison = a.createdAt.compare(b.createdAt)
            case .size:
                if a.fileSize < b.fileSize {
                    comparison = .orderedAscending
                } else if a.fileSize > b.fileSize {
                    comparison = .orderedDescending
                } else {
                    comparison = .orderedSame
                }
            case .kind:
                let groupA = FileKindGroup.kind(for: a)
                let groupB = FileKindGroup.kind(for: b)
                if groupA != groupB {
                    let indexA = FileKindGroup.allCases.firstIndex(of: groupA) ?? 0
                    let indexB = FileKindGroup.allCases.firstIndex(of: groupB) ?? 0
                    comparison = indexA < indexB ? .orderedAscending : .orderedDescending
                } else {
                    comparison = a.filename.localizedStandardCompare(b.filename)
                }
            }
            
            if comparison == .orderedSame {
                return a.filename.localizedStandardCompare(b.filename) == .orderedAscending
            }
            
            return sortAscending ? (comparison == .orderedAscending) : (comparison == .orderedDescending)
        }
        
        return items
    }
    
    /// Checks the configured NAS. Concurrent callers share one check (and wait for it) instead of
    /// returning early with a stale `nasOnline`. The check runs in its own task, so cancelling the
    /// navigation that asked for it can't make the NAS look offline.
    public func checkNASStatus() async {
        if let running = healthCheckTask {
            await running.value
            return
        }
        await startHealthCheck()
    }
    
    private func startHealthCheck() async {
        let task = Task { await self.performNASStatusCheck() }
        healthCheckTask = task
        await task.value
        if healthCheckTask == task {
            healthCheckTask = nil
        }
    }
    
    private func performNASStatusCheck() async {
        isCheckingNAS = true
        let online = await nasClient.checkHealth()
        let wasOffline = !self.nasOnline
        self.nasOnline = online
        self.nasBaseUrl = nasClient.getBaseUrl()
        
        if online {
            discoveredNASUrl = nil
            if nasClient.hasApiToken || nasAuthFailed {
                if let accepted = await nasClient.verifyAuth() {
                    if accepted {
                        nasAuthFailed = false
                    } else {
                        markAuthFailed()
                    }
                }
            }
        } else if SynapsConfig.load().autoDiscoverNas {
            // Suggest (never silently adopt) another address that answers, e.g. after a DHCP change.
            discoveredNASUrl = await nasClient.discoverNAS().first
        }
        isCheckingNAS = false
        
        if online && wasOffline && !self.fileItems.isEmpty {
            if !self.currentFolderPath.isEmpty && !self.isNASSection && !self.isPicturesSection {
                // Separate task: callers awaiting the health check shouldn't wait for a folder reconcile
                Task {
                    await self.reconcileCurrentFolder()
                }
            }
        }
    }
    
    private func reconcileCurrentFolder() async {
        let generation = loadGeneration
        let title = (currentFolderPath as NSString).lastPathComponent
        let sourceLocation = selectedSidebarItem?.title ?? title
        let sourceId = selectedSidebarItem?.sourceId ?? "mac_harsh"
        let startedAt = Date()
        let reconciled = await reconciliationEngine.reconcileDirectory(
            directoryPath: currentFolderPath,
            sourceLocation: sourceLocation,
            localItems: fileItems,
            sourceId: sourceId
        )
        mergeReconciled(reconciled, generation: generation, startedAt: startedAt)
        loadRecentActivities()
    }
    
    /// Applies a saved Settings change (posted by SettingsView): new address/token take effect now.
    public func applySettings(_ config: SynapsConfig) {
        nasClient.apply(config: config)
        nasBaseUrl = nasClient.getBaseUrl()
        nasAuthFailed = false
        discoveredNASUrl = nil
        nasOnline = false
        Task {
            // A check of the old address may be running; let it finish, then check the new one.
            if let running = self.healthCheckTask {
                await running.value
            }
            await self.startHealthCheck()
            if self.isNASSection {
                self.loadNASFolder(path: self.currentNASRelativePath)
            }
        }
    }
    
    /// Switches to the suggested NAS address after the user confirmed it.
    public func adoptDiscoveredNAS() {
        guard let url = discoveredNASUrl else { return }
        var config = SynapsConfig.load()
        config.nasUrl = url
        config.save()
        NotificationCenter.default.post(name: SynapsConfig.didChangeNotification, object: config)
    }
    
    public func loadDefaultFolder() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path ?? ""
        let item = SidebarItem(
            id: "folder_downloads",
            title: "Downloads",
            icon: "arrow.down.circle",
            section: .macFolders,
            path: downloads,
            sourceId: "mac_harsh"
        )
        self.selectedSidebarItem = item
        loadFolder(path: downloads, sourceLocation: "Downloads", sourceId: "mac_harsh")
    }
    
    @Published public var currentFolderPath: String = ""
    @Published public var navigationHistory: [String] = []
    
    public func selectSidebarItem(_ item: SidebarItem) {
        self.selectedSidebarItem = item
        self.navigationHistory = []
        self.selectedItemIds.removeAll()
        if item.isPhone {
            beginNavigation()
            scanner.cancelBackgroundHashing()
            self.isLoading = false
            self.fileItems = phoneManager.phoneMediaItems
            self.currentFolderPath = "iPhone"
        } else if item.isNAS {
            self.currentFolderPath = "Home Cloud"
            loadNASFolder(path: "")
        } else if let path = item.path {
            loadFolder(path: path, sourceLocation: item.title, sourceId: item.sourceId)
        }
    }
    
    public func selectPicturesSection() {
        let item = SidebarItem(
            id: "section_pictures",
            title: "Pictures",
            icon: "photo.on.rectangle.angled",
            section: .macFolders,
            path: nil,
            sourceId: "iphone_harsh",
            isPhone: true
        )
        beginNavigation()
        scanner.cancelBackgroundHashing()
        self.selectedSidebarItem = item
        self.navigationHistory = []
        self.currentFolderPath = "iPhone"
        self.selectedItemIds.removeAll()
        // A local folder scan still in flight must not leave the spinner up here
        self.isLoading = false
        if phoneManager.connectedDevice != nil && !phoneManager.isDeviceLocked {
            self.fileItems = phoneManager.phoneMediaItems
        } else {
            self.fileItems = []
        }
    }
    
    @Published public var lastSelectedId: String? = nil
    
    public var selectedItems: [SynapsFileItem] {
        return filteredItems.filter { selectedItemIds.contains($0.id) }
    }
    
    public var selectedUrls: [URL] {
        return selectedItems.compactMap { item -> URL? in
            if item.originalPath.hasPrefix("iPhone://") || item.originalPath.hasPrefix("nas://") {
                return nil
            }
            return URL(fileURLWithPath: item.originalPath)
        }
    }
    
    private var lastClickTime: TimeInterval = 0
    private var lastClickedItemId: String? = nil
    
    public func handleItemClick(
        _ item: SynapsFileItem,
        commandKey: Bool = false,
        shiftKey: Bool = false,
        onDoubleClick: (() -> Void)? = nil
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let isDoubleClick = (lastClickedItemId == item.id && (now - lastClickTime) < NSEvent.doubleClickInterval) || (NSApp.currentEvent?.clickCount ?? 1) >= 2
        
        lastClickTime = now
        lastClickedItemId = item.id
        
        if commandKey {
            if selectedItemIds.contains(item.id) {
                selectedItemIds.remove(item.id)
            } else {
                selectedItemIds.insert(item.id)
                lastSelectedId = item.id
            }
        } else if shiftKey, let lastId = lastSelectedId,
                  let lastIdx = filteredItems.firstIndex(where: { $0.id == lastId }),
                  let currentIdx = filteredItems.firstIndex(where: { $0.id == item.id }) {
            let range = min(lastIdx, currentIdx)...max(lastIdx, currentIdx)
            let visible = filteredItems
            selectedItemIds.formUnion(range.map { visible[$0].id })
        } else {
            selectedItemIds = [item.id]
            lastSelectedId = item.id
        }
        
        if isDoubleClick {
            onDoubleClick?()
        }
    }
    
    public func toggleSelection(id: String) {
        if selectedItemIds.contains(id) {
            selectedItemIds.remove(id)
        } else {
            selectedItemIds.insert(id)
            lastSelectedId = id
        }
    }
    
    public func clearSelection() {
        selectedItemIds.removeAll()
        lastSelectedId = nil
    }
    
    public func selectAll() {
        selectedItemIds = Set(filteredItems.map { $0.id })
    }
    
    public func deselectAll() {
        selectedItemIds.removeAll()
        lastSelectedId = nil
    }
    
    public func toggleQuickLook() {
        QuickLookCoordinator.shared.toggleQuickLook(for: selectedUrls)
    }
    
    public func importSelectedItems() {
        let ids = filteredItems.filter { selectedItemIds.contains($0.id) }.map { $0.id }
        importPhoneItems(ids: ids)
    }
    
    public func importAllItems() {
        importPhoneItems(ids: filteredItems.map { $0.id })
    }
    
    private func importPhoneItems(ids: [String]) {
        guard !ids.isEmpty, !phoneManager.isImporting else { return }
        Task {
            await phoneManager.importItems(ids: ids)
            self.selectedItemIds.removeAll()
            if self.isPicturesSection {
                self.fileItems = self.phoneManager.phoneMediaItems
            }
        }
    }
    
    public func navigateIntoFolder(path: String, title: String, sourceId: String) {
        if isNASSection || path.hasPrefix("nas://") {
            navigationHistory.append(currentNASRelativePath)
            let relativePath = path.replacingOccurrences(of: "nas://", with: "")
            loadNASFolder(path: relativePath)
            return
        }
        if !currentFolderPath.isEmpty {
            navigationHistory.append(currentFolderPath)
        }
        loadFolder(path: path, sourceLocation: title, sourceId: sourceId)
    }
    
    public func navigateBack() {
        guard let prev = navigationHistory.popLast() else { return }
        if isNASSection {
            loadNASFolder(path: prev)
            return
        }
        let title = (prev as NSString).lastPathComponent
        loadFolder(path: prev, sourceLocation: title, sourceId: selectedSidebarItem?.sourceId ?? "mac_harsh")
    }
    
    public func loadNASFolder(path: String = "") {
        let generation = beginNavigation()
        scanner.cancelBackgroundHashing()
        self.currentNASRelativePath = path
        self.currentFolderPath = path.isEmpty ? "Home Cloud" : "Home Cloud/\(path)"
        self.isLoading = true
        self.fileItems = []
        self.selectedItemIds.removeAll()
        
        loadTask = Task {
            if !self.nasOnline {
                await self.checkNASStatus()
            }
            guard generation == self.loadGeneration else { return }
            
            guard self.nasOnline else {
                self.isLoading = false
                self.syncStatusMessage = "Home Cloud is offline"
                return
            }
            
            do {
                let firstPage = try await self.nasClient.browseDirectory(path: path, page: 1, perPage: 1000)
                
                // If directory has more than 1,000 files, fetch the remaining pages so full-folder sorting works seamlessly
                var allRemoteFiles = firstPage.files
                if firstPage.total_files > firstPage.files.count {
                    allRemoteFiles = try await self.nasClient.browseAllDirectoryFiles(path: path, firstPage: firstPage)
                }
                guard generation == self.loadGeneration else { return }
                
                let items = await Self.makeNASItems(folders: firstPage.folders, files: allRemoteFiles)
                guard generation == self.loadGeneration else { return }
                self.fileItems = items
                self.isLoading = false
                self.syncStatusMessage = "Home Cloud: \(firstPage.total_folders) folders, \(allRemoteFiles.count) files"
            } catch {
                guard generation == self.loadGeneration, !NASClient.isCancellation(error) else { return }
                self.isLoading = false
                self.syncStatusMessage = "Failed to load NAS contents: \(error.localizedDescription)"
            }
        }
    }
    
    /// Converts a browse listing into items off the main thread (thousands of date parses).
    nonisolated private static func makeNASItems(folders: [NASFolderItem], files: [NASFileItem]) async -> [SynapsFileItem] {
        return await Task.detached(priority: .userInitiated) {
            var items: [SynapsFileItem] = []
            items.reserveCapacity(folders.count + files.count)
            
            for folder in folders {
                let date = parseDate(folder.modified) ?? Date()
                items.append(SynapsFileItem(
                    id: "nas://" + folder.path,
                    originalPath: "nas://" + folder.path,
                    filename: folder.name,
                    fileSize: 0,
                    sourceLocation: "Home Cloud",
                    modifiedAt: date,
                    createdAt: date,
                    sha256: nil,
                    syncStatus: .committed,
                    isDirectory: true,
                    isFavorite: false,
                    albumName: nil,
                    sourceId: "nas_homecloud",
                    isLivePhotoVideo: false
                ))
            }
            
            for file in files {
                let date = parseDate(file.modified) ?? Date()
                let ext = (file.name as NSString).pathExtension.lowercased()
                items.append(SynapsFileItem(
                    id: "nas://" + file.path,
                    originalPath: "nas://" + file.path,
                    filename: file.name,
                    fileSize: file.size,
                    sourceLocation: "Home Cloud",
                    modifiedAt: date,
                    createdAt: date,
                    sha256: nil,
                    syncStatus: .committed,
                    isDirectory: false,
                    isFavorite: false,
                    albumName: nil,
                    sourceId: "nas_homecloud",
                    isLivePhotoVideo: ext == "mov"
                ))
            }
            return items
        }.value
    }
    
    public func downloadNASItem(_ item: SynapsFileItem) {
        guard isNASSection && !item.isDirectory else { return }
        let relativePath = item.originalPath.replacingOccurrences(of: "nas://", with: "")
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let destUrl = downloadsDir.appendingPathComponent(item.filename)
        
        syncStatusMessage = "Downloading \(item.filename)..."
        nasTransferMessage = "Downloading \(item.filename)..."
        Task {
            do {
                // Never overwrites: an existing "name.ext" makes this "name (1).ext"
                let savedUrl = try await nasClient.downloadFile(relativePath: relativePath, destinationURL: destUrl)
                self.syncStatusMessage = "Downloaded \(savedUrl.lastPathComponent) to Downloads"
                self.nasTransferMessage = "Downloaded \(savedUrl.lastPathComponent) to Downloads"
                self.cacheStore.logActivity(
                    eventType: .fileSynced,
                    filePath: savedUrl.path,
                    filename: savedUrl.lastPathComponent,
                    details: "Downloaded from Home Cloud to Downloads"
                )
                self.loadRecentActivities()
            } catch {
                self.syncStatusMessage = "Download failed: \(error.localizedDescription)"
                self.nasTransferMessage = "Download of \(item.filename) failed: \(error.localizedDescription)"
                self.cacheStore.logActivity(
                    eventType: .syncFailed,
                    filePath: item.originalPath,
                    filename: item.filename,
                    details: "Download failed: \(error.localizedDescription)"
                )
                self.loadRecentActivities()
            }
        }
    }
    
    public func loadFolder(path: String, sourceLocation: String, sourceId: String) {
        let generation = beginNavigation()
        currentFolderPath = path
        isLoading = true
        fileItems = []
        
        loadTask = Task {
            let items = await scanner.scanDirectory(
                directoryPath: path,
                sourceLocation: sourceLocation,
                sourceId: sourceId
            )
            guard generation == self.loadGeneration else { return }
            self.fileItems = items
            self.isLoading = false
            // Keep the selection on refresh; drop ids that aren't in this folder
            self.selectedItemIds.formIntersection(items.map { $0.id })
            
            // Run authoritative NAS reconciliation
            if self.nasOnline {
                let startedAt = Date()
                let reconciled = await self.reconciliationEngine.reconcileDirectory(
                    directoryPath: path,
                    sourceLocation: sourceLocation,
                    localItems: items,
                    sourceId: sourceId
                )
                self.mergeReconciled(reconciled, generation: generation, startedAt: startedAt)
                self.loadRecentActivities()
            }
        }
    }
    
    public func refreshCurrentFolder() {
        if isNASSection {
            loadNASFolder(path: currentNASRelativePath)
        } else if isPicturesSection {
            phoneManager.checkDeviceStatus()
            self.fileItems = phoneManager.phoneMediaItems
        } else if !currentFolderPath.isEmpty {
            let title = (currentFolderPath as NSString).lastPathComponent
            loadFolder(
                path: currentFolderPath,
                sourceLocation: selectedSidebarItem?.title ?? title,
                sourceId: selectedSidebarItem?.sourceId ?? "mac_harsh"
            )
        } else if let sel = selectedSidebarItem {
            selectSidebarItem(sel)
        }
    }
    
    public func runPreCheckDeduplication(items: [SynapsFileItem], sourceId: String) async {
        guard nasOnline else { return }
        let generation = loadGeneration
        let startedAt = Date()
        let reconciled = await reconciliationEngine.reconcileHashedItems(
            hashedItems: items,
            currentFileItems: self.fileItems,
            sourceId: sourceId
        )
        mergeReconciled(reconciled, generation: generation, startedAt: startedAt)
        self.loadRecentActivities()
    }
    
    public func syncAllUncommitted() {
        guard !isSyncing else { return }
        if isPicturesSection {
            importAllItems()
            return
        }
        guard nasOnline else {
            syncStatusMessage = "Cannot sync: NAS is offline"
            return
        }
        
        let toSync = uncommittedItems
        guard !toSync.isEmpty else {
            syncStatusMessage = "All files are already committed!"
            return
        }
        
        // Uncommitted subfolders are expanded to their files (they used to be handed to the
        // uploader as if they were files).
        syncSelection(toSync, title: "Committing \(toSync.count) items")
    }
    
    public func syncItem(_ item: SynapsFileItem) {
        if isPicturesSection || item.originalPath.hasPrefix("iPhone://") {
            importPhoneItems(ids: [item.id])
            return
        }
        guard !isSyncing else { return }
        
        if item.isDirectory {
            syncSelection([item], title: "Syncing folder \(item.filename)")
        } else {
            startSyncProcess(for: [item], title: "Syncing \(item.filename)")
        }
    }
    
    public func syncSelectedItems() {
        guard !isSyncing else { return }
        if isPicturesSection {
            importSelectedItems()
            return
        }
        
        let targets = selectedItems
        guard !targets.isEmpty else {
            syncStatusMessage = "No items selected to sync"
            return
        }
        syncSelection(targets, title: nil)
    }
    
    /// Expands folders (recursively, off the main thread) and syncs everything not yet committed.
    private func syncSelection(_ targets: [SynapsFileItem], title: String?) {
        guard nasOnline else {
            syncStatusMessage = "Cannot sync: NAS is offline"
            return
        }
        let directories = targets.filter { $0.isDirectory }
        setStatus(.syncing, forPaths: directories.map { $0.originalPath })
        // Hold the sync slot while scanning so a second click can't start a parallel run
        isSyncing = true
        lastSyncSummary = nil
        if !directories.isEmpty {
            syncStatusMessage = "Scanning \(directories.count == 1 ? directories[0].filename : "\(directories.count) folders")..."
        }
        
        // Stored so Cancel also works while folders are still being scanned
        syncTask = Task {
            var toSync: [SynapsFileItem] = []
            var seenPaths = Set<String>()
            for item in targets {
                if Task.isCancelled {
                    break
                }
                if item.isDirectory {
                    let dirFiles = await self.scanner.scanDirectoryRecursivelyAsync(
                        directoryPath: item.originalPath,
                        sourceLocation: item.sourceLocation,
                        sourceId: item.sourceId
                    ).filter { $0.syncStatus != .committed }
                    for f in dirFiles where seenPaths.insert(f.originalPath).inserted {
                        toSync.append(f)
                    }
                } else if item.syncStatus != .committed && seenPaths.insert(item.originalPath).inserted {
                    toSync.append(item)
                }
            }
            
            self.isSyncing = false
            self.syncTask = nil
            if Task.isCancelled {
                self.syncStatusMessage = "Sync cancelled"
                self.lastSyncSummary = self.syncStatusMessage
                await self.refreshDirectoryStatuses()
                return
            }
            guard !toSync.isEmpty else {
                self.syncStatusMessage = directories.count == 1 && targets.count == 1
                    ? "All files in folder are already committed"
                    : "Selected items are already committed!"
                self.lastSyncSummary = self.syncStatusMessage
                await self.refreshDirectoryStatuses()
                return
            }
            // e.g. the NAS went offline while scanning: put the folders' badges back
            if !self.startSyncProcess(for: toSync, title: title ?? "Syncing \(toSync.count) selected items") {
                await self.refreshDirectoryStatuses()
            }
        }
    }
    
    @discardableResult
    private func startSyncProcess(for toSync: [SynapsFileItem], title: String) -> Bool {
        guard !isSyncing else { return false }
        guard nasOnline else {
            syncStatusMessage = "Cannot sync: NAS is offline"
            return false
        }
        // The engine hashes what it uploads; background hashing of the same files would read
        // every multi-GB file twice at the same time.
        scanner.cancelBackgroundHashing()
        
        isSyncing = true
        syncProgress = 0.0
        syncSpeedMBs = 0.0
        lastSyncSummary = nil
        syncStatusMessage = "Starting sync of \(toSync.count) files..."
        activeSyncPaths = Set(toSync.map { $0.originalPath })
        
        cacheStore.logActivity(
            eventType: .syncStarted,
            details: "Started sync of \(toSync.count) files",
            sourceId: toSync.first?.sourceId
        )
        loadRecentActivities()
        
        // Hashing, pre-check and uploads all run off the main thread inside the engine.
        let engine = syncEngine
        syncTask = Task {
            let summary = await engine.run(items: toSync) { event in
                await self.handleSyncEvent(event)
            }
            self.finishSync(summary, sourceId: toSync.first?.sourceId)
        }
        return true
    }
    
    /// Stops the running sync; files already uploaded stay committed.
    public func cancelSync() {
        guard isSyncing, let task = syncTask else { return }
        task.cancel()
        syncStatusMessage = "Cancelling sync..."
    }
    
    private func handleSyncEvent(_ event: SyncEngine.Event) {
        switch event {
        case .progress(let progress):
            // Never move backwards (e.g. while a failed upload is retried)
            syncProgress = max(syncProgress, progress.fraction)
            syncSpeedMBs = progress.bytesPerSecond / (1024 * 1024)
            if syncTask?.isCancelled == true {
                syncStatusMessage = "Cancelling sync..."
            } else if !progress.message.isEmpty {
                syncStatusMessage = "[\(progress.completedFiles)/\(progress.totalFiles)] \(progress.message)"
            }
        case .started(let paths):
            setStatus(.syncing, forPaths: paths)
        case .finished(let results):
            applySyncResults(results)
        }
    }
    
    private func applySyncResults(_ results: [SyncEngine.ItemResult]) {
        let now = Date()
        var indexByPath: [String: Int] = [:]
        for (i, item) in fileItems.enumerated() {
            indexByPath[item.originalPath] = i
        }
        var items = fileItems
        var changed = false
        for result in results {
            let path = result.item.originalPath
            activeSyncPaths.remove(path)
            // Most files of a folder sync live in subfolders and aren't on screen
            guard let idx = indexByPath[path] else { continue }
            changed = true
            switch result.outcome {
            case .uploaded, .alreadyOnNAS:
                items[idx].syncStatus = .committed
                if let sha = result.item.sha256 {
                    items[idx].sha256 = sha
                }
                committedAt[path] = now
            case .failed:
                items[idx].syncStatus = .failed
            case .cancelled:
                // Back to what it was before the sync started
                items[idx].syncStatus = result.item.syncStatus == .syncing ? .uncommitted : result.item.syncStatus
            }
        }
        if changed {
            fileItems = items
        }
    }
    
    private func finishSync(_ summary: SyncEngine.Summary, sourceId: String?) {
        activeSyncPaths.removeAll()
        syncTask = nil
        isSyncing = false
        syncSpeedMBs = 0.0
        syncProgress = summary.cancelled == 0 ? 1.0 : syncProgress
        
        var parts = ["Committed \(summary.committed) files"]
        if summary.alreadyOnNAS > 0 {
            parts.append("\(summary.alreadyOnNAS) already on NAS")
        }
        if summary.failed > 0 {
            parts.append("\(summary.failed) failed")
        }
        if summary.cancelled > 0 {
            parts.append("\(summary.cancelled) cancelled")
        }
        let message = parts.joined(separator: ", ") + " in \(String(format: "%.1f", summary.elapsed))s"
        if summary.unauthorized {
            syncStatusMessage = "Sync stopped: API token missing or wrong. Check Settings."
        } else if summary.diskFull {
            syncStatusMessage = "Sync stopped: Home Cloud's disk is full. " + message
        } else {
            syncStatusMessage = message
        }
        lastSyncSummary = syncStatusMessage
        
        cacheStore.logActivity(
            eventType: summary.failed > 0 || summary.unauthorized || summary.diskFull ? .syncFailed : .syncCompleted,
            details: syncStatusMessage,
            sourceId: sourceId
        )
        loadRecentActivities()
        
        Task {
            await self.refreshDirectoryStatuses()
        }
        
        if summary.cancelled == 0 {
            let detail = summary.failed > 0 ? " (\(summary.failed) failed)" : ""
            notify(title: "Synaps NAS Sync", message: "Synced \(summary.committed) files to NAS Vault\(detail).")
        }
    }
    
    public func loadRecentActivities() {
        self.recentActivities = cacheStore.getRecentActivity(limit: 100)
    }
    
    public func clearRecentActivities() {
        cacheStore.clearActivityLog()
        self.recentActivities = []
    }
    
    private func notify(title: String, message: String) {
        UserNotifier.shared.post(title: title, message: message)
    }
    
    // MARK: - Helpers
    
    /// Invalidates in-flight work of the previous folder and returns the new generation.
    @discardableResult
    private func beginNavigation() -> Int {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        lastSyncSummary = nil
        nasTransferMessage = nil
        committedAt.removeAll()
        return loadGeneration
    }
    
    /// Applies file statuses/hashes from a reconciliation pass (started at `startedAt`) to the items
    /// on screen, matched by path. Dropped if the user navigated away meanwhile; files in the running
    /// sync keep their live status, and files a sync committed after the pass began stay committed.
    private func mergeReconciled(_ reconciled: [SynapsFileItem], generation: Int, startedAt: Date) {
        guard generation == loadGeneration else { return }
        var byPath: [String: SynapsFileItem] = [:]
        for item in reconciled where !item.isDirectory {
            byPath[item.originalPath] = item
        }
        var items = fileItems
        var changed = false
        for i in items.indices where !items[i].isDirectory {
            let path = items[i].originalPath
            guard let r = byPath[path], !activeSyncPaths.contains(path), items[i].syncStatus != .syncing else { continue }
            if let committed = committedAt[path], committed >= startedAt, r.syncStatus != .committed {
                continue
            }
            if items[i].syncStatus != r.syncStatus {
                items[i].syncStatus = r.syncStatus
                changed = true
            }
            if items[i].sha256 == nil, let sha = r.sha256 {
                items[i].sha256 = sha
                changed = true
            }
        }
        if changed {
            fileItems = items
        }
    }
    
    private func setStatus(_ status: SyncStatus, forPaths paths: [String]) {
        guard !paths.isEmpty else { return }
        let targets = Set(paths)
        var items = fileItems
        var changed = false
        for i in items.indices where targets.contains(items[i].originalPath) && items[i].syncStatus != status {
            items[i].syncStatus = status
            changed = true
        }
        if changed {
            fileItems = items
        }
    }
    
    /// Re-evaluates the on-screen folders' statuses (recursive walks) off the main thread.
    private func refreshDirectoryStatuses() async {
        guard !isNASSection && !isPicturesSection else { return }
        let generation = loadGeneration
        let folderPaths = fileItems.filter { $0.isDirectory }.map { $0.originalPath }
        guard !folderPaths.isEmpty else { return }
        let statuses = await scanner.evaluateFolderSyncStatuses(folderPaths: folderPaths)
        guard generation == loadGeneration else { return }
        var items = fileItems
        var changed = false
        for i in items.indices where items[i].isDirectory {
            if let status = statuses[items[i].originalPath], items[i].syncStatus != status {
                items[i].syncStatus = status
                changed = true
            }
        }
        if changed {
            fileItems = items
        }
    }
}

/// Tolerant, thread-safe parser for the timestamps the NAS returns. Accepts "2026-10-13",
/// "2026-10-13T14:59:00", "2026-10-13 14:59:00.123456", "...Z", "...+05:30", "...+0530".
enum NASDateParser {
    private static let pattern = try? NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#
    )
    
    static func parse(_ string: String?) -> Date? {
        guard let raw = string?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let regex = pattern else { return nil }
        let ns = raw as NSString
        guard let match = regex.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        func group(_ index: Int) -> String? {
            let range = match.range(at: index)
            return range.location == NSNotFound ? nil : ns.substring(with: range)
        }
        func number(_ index: Int) -> Int? {
            return group(index).flatMap { Int($0) }
        }
        
        guard let year = number(1), let month = number(2), let day = number(3),
              (1...12).contains(month), (1...31).contains(day) else { return nil }
        
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = number(4) ?? 0
        components.minute = number(5) ?? 0
        components.second = number(6) ?? 0
        if let fraction = group(7) {
            components.nanosecond = Int(String((fraction + "000000000").prefix(9)))
        }
        
        let timeZone: TimeZone
        if let zone = group(8) {
            if zone == "Z" || zone == "z" {
                timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            } else {
                let sign = zone.hasPrefix("-") ? -1 : 1
                let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = digits.count >= 4 ? (Int(digits.dropFirst(2).prefix(2)) ?? 0) : 0
                timeZone = TimeZone(secondsFromGMT: sign * (hours * 3600 + minutes * 60)) ?? .current
            }
        } else {
            // Naive timestamps are NAS local time; the NAS and this Mac share a time zone.
            timeZone = .current
        }
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }
}
