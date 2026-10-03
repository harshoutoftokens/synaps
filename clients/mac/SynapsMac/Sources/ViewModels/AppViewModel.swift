import Foundation
import SwiftUI
import Combine

@MainActor
public final class AppViewModel: ObservableObject {
    @Published public var selectedSidebarItem: SidebarItem?
    @Published public var fileItems: [SynapsFileItem] = []
    @Published public var isLoading: Bool = false
    @Published public var isSyncing: Bool = false
    @Published public var syncProgress: Double = 0.0
    @Published public var syncSpeedMBs: Double = 0.0
    @Published public var syncStatusMessage: String = "Ready"
    @Published public var nasOnline: Bool = false
    @Published public var isCheckingNAS: Bool = false
    @Published public var nasBaseUrl: String = NASClient.shared.getBaseUrl()
    @Published public var searchQuery: String = ""
    @Published public var filterSelection: FilterOption = .all
    @Published public var sortField: SortField = .dateCreated
    @Published public var sortAscending: Bool = false
    @Published public var selectedItemIds: Set<String> = []
    @Published public var recentActivities: [SyncActivityItem] = []
    @Published public var showActivityLog: Bool = false
    @Published public var collapsedKinds: Set<String> = []
    
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
    
    /// Parses dates from ISO8601 strings (with or without timezone and with or without fractional seconds)
    public static func parseDate(_ string: String?) -> Date? {
        guard let string = string, !string.isEmpty else { return nil }
        
        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoWithFraction.date(from: string) { return d }
        
        let isoStandard = ISO8601DateFormatter()
        isoStandard.formatOptions = [.withInternetDateTime]
        if let d = isoStandard.date(from: string) { return d }
        
        let isoNoTz = ISO8601DateFormatter()
        isoNoTz.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let d = isoNoTz.date(from: string) { return d }
        
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss"] {
            df.dateFormat = fmt
            if let d = df.date(from: string) { return d }
        }
        return nil
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
    public let phoneManager = iPhoneManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    private var nasRecoveryTimer: Timer?
    
    public init() {
        setupPhoneObserver()
        setupScannerObserver()
        setupSelectionNotifications()
        setupLifecycleObservers()
        startNASRecoveryTimer()
        Task {
            await checkNASStatus()
            loadDefaultFolder()
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
                let map = Dictionary(uniqueKeysWithValues: hashedItems.compactMap { item -> (String, String)? in
                    guard let sha = item.sha256 else { return nil }
                    return (item.originalPath, sha)
                })
                for i in 0..<self.fileItems.count {
                    if let sha = map[self.fileItems[i].originalPath] {
                        self.fileItems[i].sha256 = sha
                    }
                }
                
                if self.nasOnline {
                    let sourceId = self.selectedSidebarItem?.sourceId ?? "mac_harsh"
                    let reconciled = await self.reconciliationEngine.reconcileHashedItems(
                        hashedItems: hashedItems,
                        currentFileItems: self.fileItems,
                        sourceId: sourceId
                    )
                    self.fileItems = reconciled
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
                    .filter { ids.contains($0.id) && !$0.originalPath.hasPrefix("iPhone://") }
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
    
    public func checkNASStatus() async {
        guard !isCheckingNAS else { return }
        await MainActor.run {
            self.isCheckingNAS = true
        }
        defer {
            Task { @MainActor in
                self.isCheckingNAS = false
            }
        }
        
        let online = await nasClient.checkHealth()
        let currentUrl = nasClient.getBaseUrl()
        let wasOffline = !self.nasOnline
        
        await MainActor.run {
            self.nasOnline = online
            self.nasBaseUrl = currentUrl
        }
        
        if online && wasOffline && !self.fileItems.isEmpty {
            if !self.currentFolderPath.isEmpty && !self.isNASSection && !self.isPicturesSection {
                let title = (self.currentFolderPath as NSString).lastPathComponent
                let sourceLocation = self.selectedSidebarItem?.title ?? title
                let sourceId = self.selectedSidebarItem?.sourceId ?? "mac_harsh"
                let reconciled = await self.reconciliationEngine.reconcileDirectory(
                    directoryPath: self.currentFolderPath,
                    sourceLocation: sourceLocation,
                    localItems: self.fileItems,
                    sourceId: sourceId
                )
                self.fileItems = reconciled
                self.loadRecentActivities()
            }
        }
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
        self.selectedSidebarItem = item
        self.navigationHistory = []
        self.currentFolderPath = "iPhone"
        self.selectedItemIds.removeAll()
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
            if item.originalPath.hasPrefix("iPhone://") {
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
            for i in range {
                selectedItemIds.insert(filteredItems[i].id)
            }
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
        let filenames = filteredItems.filter { selectedItemIds.contains($0.id) }.map { $0.filename }
        Task {
            await phoneManager.importItems(filenames: filenames)
            self.selectedItemIds.removeAll()
            if self.isPicturesSection {
                self.fileItems = self.phoneManager.phoneMediaItems
            }
        }
    }
    
    public func importAllItems() {
        let filenames = filteredItems.map { $0.filename }
        Task {
            await phoneManager.importItems(filenames: filenames)
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
        self.currentNASRelativePath = path
        self.currentFolderPath = path.isEmpty ? "Home Cloud" : "Home Cloud/\(path)"
        self.isLoading = true
        self.fileItems = []
        self.selectedItemIds.removeAll()
        
        Task {
            if !self.nasOnline {
                await self.checkNASStatus()
            }
            
            guard self.nasOnline else {
                await MainActor.run {
                    self.isLoading = false
                    self.syncStatusMessage = "Home Cloud is offline"
                }
                return
            }
            
            do {
                let firstPage = try await self.nasClient.browseDirectory(path: path, page: 1, perPage: 1000)
                var items: [SynapsFileItem] = []
                
                for folder in firstPage.folders {
                    let date = Self.parseDate(folder.modified) ?? Date()
                    let item = SynapsFileItem(
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
                    )
                    items.append(item)
                }
                
                // If directory has more than 1,000 files, fetch all pages so full-folder sorting works seamlessly
                var allRemoteFiles = firstPage.files
                if firstPage.total_files > firstPage.files.count {
                    let fullFiles = try await self.nasClient.browseAllDirectoryFiles(path: path)
                    if !fullFiles.isEmpty {
                        allRemoteFiles = fullFiles
                    }
                }
                
                for file in allRemoteFiles {
                    let date = Self.parseDate(file.modified) ?? Date()
                    let ext = (file.name as NSString).pathExtension.lowercased()
                    let item = SynapsFileItem(
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
                    )
                    items.append(item)
                }
                
                await MainActor.run {
                    self.fileItems = items
                    self.isLoading = false
                    self.syncStatusMessage = "Home Cloud: \(firstPage.total_folders) folders, \(allRemoteFiles.count) files"
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    self.syncStatusMessage = "Failed to load NAS contents: \(error.localizedDescription)"
                }
            }
        }
    }
    
    public func downloadNASItem(_ item: SynapsFileItem) {
        guard isNASSection && !item.isDirectory else { return }
        let relativePath = item.originalPath.replacingOccurrences(of: "nas://", with: "")
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
        let destUrl = downloadsDir.appendingPathComponent(item.filename)
        
        syncStatusMessage = "Downloading \(item.filename)..."
        Task {
            do {
                let success = try await nasClient.downloadFile(relativePath: relativePath, destinationURL: destUrl)
                await MainActor.run {
                    if success {
                        self.syncStatusMessage = "Downloaded \(item.filename) to Downloads"
                        self.cacheStore.logActivity(
                            eventType: .fileSynced,
                            filePath: destUrl.path,
                            filename: item.filename,
                            details: "Downloaded from Home Cloud to Downloads"
                        )
                        self.loadRecentActivities()
                    } else {
                        self.syncStatusMessage = "Failed to download \(item.filename)"
                    }
                }
            } catch {
                await MainActor.run {
                    self.syncStatusMessage = "Download failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    public func loadFolder(path: String, sourceLocation: String, sourceId: String) {
        currentFolderPath = path
        isLoading = true
        fileItems = []
        
        Task {
            let items = await scanner.scanDirectory(
                directoryPath: path,
                sourceLocation: sourceLocation,
                sourceId: sourceId
            )
            guard self.currentFolderPath == path else { return }
            self.fileItems = items
            self.isLoading = false
            
            // Run authoritative NAS reconciliation
            if self.nasOnline {
                let reconciled = await self.reconciliationEngine.reconcileDirectory(
                    directoryPath: path,
                    sourceLocation: sourceLocation,
                    localItems: items,
                    sourceId: sourceId
                )
                guard self.currentFolderPath == path else { return }
                self.fileItems = reconciled
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
        let reconciled = await reconciliationEngine.reconcileHashedItems(
            hashedItems: items,
            currentFileItems: self.fileItems,
            sourceId: sourceId
        )
        self.fileItems = reconciled
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
        
        startSyncProcess(for: toSync, title: "Committing \(toSync.count) files")
    }
    
    public func syncItem(_ item: SynapsFileItem) {
        if isPicturesSection || item.originalPath.hasPrefix("iPhone://") {
            Task {
                await phoneManager.importItems(filenames: [item.filename])
                if self.isPicturesSection {
                    self.fileItems = self.phoneManager.phoneMediaItems
                }
            }
            return
        }
        
        if item.isDirectory {
            if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                fileItems[idx].syncStatus = .syncing
            }
            let files = LocalFileScanner.shared.scanDirectoryRecursively(
                directoryPath: item.originalPath,
                sourceLocation: item.sourceLocation,
                sourceId: item.sourceId
            ).filter { $0.syncStatus != .committed }
            guard !files.isEmpty else {
                syncStatusMessage = "All files in folder are already committed"
                if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                    fileItems[idx].syncStatus = .committed
                }
                return
            }
            startSyncProcess(for: files, title: "Syncing folder \(item.filename)")
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
        guard nasOnline else {
            syncStatusMessage = "Cannot sync: NAS is offline"
            return
        }
        
        let targets = selectedItems
        guard !targets.isEmpty else {
            syncStatusMessage = "No items selected to sync"
            return
        }
        
        var toSync: [SynapsFileItem] = []
        var seenPaths = Set<String>()
        
        for item in targets {
            if item.isDirectory {
                if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                    fileItems[idx].syncStatus = .syncing
                }
                let dirFiles = LocalFileScanner.shared.scanDirectoryRecursively(
                    directoryPath: item.originalPath,
                    sourceLocation: item.sourceLocation,
                    sourceId: item.sourceId
                ).filter { $0.syncStatus != .committed }
                for f in dirFiles {
                    if !seenPaths.contains(f.originalPath) {
                        seenPaths.insert(f.originalPath)
                        toSync.append(f)
                    }
                }
            } else {
                if !seenPaths.contains(item.originalPath) && item.syncStatus != .committed {
                    seenPaths.insert(item.originalPath)
                    toSync.append(item)
                }
            }
        }
        
        guard !toSync.isEmpty else {
            syncStatusMessage = "Selected items are already committed!"
            for i in 0..<fileItems.count {
                if fileItems[i].isDirectory {
                    fileItems[i].syncStatus = LocalFileScanner.shared.evaluateFolderSyncStatus(folderPath: fileItems[i].originalPath)
                }
            }
            return
        }
        
        startSyncProcess(for: toSync, title: "Syncing \(toSync.count) selected items")
    }
    
    private func startSyncProcess(for toSync: [SynapsFileItem], title: String) {
        guard !isSyncing else { return }
        guard nasOnline else {
            syncStatusMessage = "Cannot sync: NAS is offline"
            return
        }
        
        isSyncing = true
        syncProgress = 0.0
        syncStatusMessage = "Starting sync of \(toSync.count) files..."
        
        cacheStore.logActivity(
            eventType: .syncStarted,
            details: "Started sync of \(toSync.count) files",
            sourceId: toSync.first?.sourceId
        )
        loadRecentActivities()
        
        Task {
            let total = toSync.count
            var uploadedCount = 0
            let startTime = Date()
            var totalBytesUploaded: Int64 = 0
            
            // Step 1: Pre-compute hashes and run batch pre-check deduplication if possible
            var itemsPendingUpload: [SynapsFileItem] = []
            var itemsWithSha: [SynapsFileItem] = []
            
            for var item in toSync {
                if item.sha256 == nil || item.sha256?.isEmpty == true {
                    if let sha = HashEngine.computeSHA256(for: item.originalPath) {
                        item.sha256 = sha
                    }
                }
                if item.sha256 != nil {
                    itemsWithSha.append(item)
                } else {
                    itemsPendingUpload.append(item)
                }
            }
            
            if !itemsWithSha.isEmpty {
                do {
                    let precheckResp = try await nasClient.batchPreCheck(
                        sourceId: itemsWithSha.first?.sourceId ?? "mac_harsh",
                        friendlyName: "Harsh's Mac",
                        platform: "macOS",
                        items: itemsWithSha
                    )
                    
                    var dedupPaths = Set<String>()
                    for res in precheckResp.results {
                        if res.status == "dedup_linked" {
                            dedupPaths.insert(res.original_path)
                            if let targetItem = itemsWithSha.first(where: { $0.originalPath == res.original_path }) {
                                cacheStore.recordItemSynced(
                                    path: targetItem.originalPath,
                                    fileSize: targetItem.fileSize,
                                    modifiedAt: targetItem.modifiedAt,
                                    sha256: targetItem.sha256,
                                    album: targetItem.albumName,
                                    isFavorite: targetItem.isFavorite
                                )
                            } else {
                                cacheStore.markSynced(paths: [res.original_path], status: .committed)
                            }
                            
                            cacheStore.logActivity(
                                eventType: .existingDiscovered,
                                filePath: res.original_path,
                                filename: (res.original_path as NSString).lastPathComponent,
                                details: "Existing file detected on NAS (dedup linked)",
                                sourceId: itemsWithSha.first?.sourceId
                            )
                            if let idx = fileItems.firstIndex(where: { $0.originalPath == res.original_path }) {
                                fileItems[idx].syncStatus = .committed
                            }
                            uploadedCount += 1
                        }
                    }
                    
                    for item in itemsWithSha {
                        if !dedupPaths.contains(item.originalPath) {
                            itemsPendingUpload.append(item)
                        }
                    }
                } catch {
                    itemsPendingUpload.append(contentsOf: itemsWithSha)
                }
            }
            
            // Step 2: Upload remaining files
            for (index, item) in itemsPendingUpload.enumerated() {
                self.syncStatusMessage = "[\(uploadedCount + index + 1)/\(total)] Syncing \(item.filename)..."
                
                if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                    fileItems[idx].syncStatus = .syncing
                }
                
                let t0 = Date()
                do {
                    let success = try await nasClient.uploadFile(item: item, sourceId: item.sourceId)
                    if success {
                        uploadedCount += 1
                        totalBytesUploaded += item.fileSize
                        let dt = max(Date().timeIntervalSince(t0), 0.001)
                        let speed = (Double(item.fileSize) / (1024 * 1024)) / dt
                        self.syncSpeedMBs = speed
                        
                        cacheStore.recordItemSynced(
                            path: item.originalPath,
                            fileSize: item.fileSize,
                            modifiedAt: item.modifiedAt,
                            sha256: item.sha256,
                            album: item.albumName,
                            isFavorite: item.isFavorite
                        )
                        cacheStore.logActivity(
                            eventType: .fileSynced,
                            filePath: item.originalPath,
                            filename: item.filename,
                            details: "Uploaded \(item.formattedSize) to NAS Vault",
                            sourceId: item.sourceId
                        )
                        if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                            fileItems[idx].syncStatus = .committed
                        }
                    } else {
                        cacheStore.logActivity(
                            eventType: .syncFailed,
                            filePath: item.originalPath,
                            filename: item.filename,
                            details: "Upload rejected by server",
                            sourceId: item.sourceId
                        )
                        if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                            fileItems[idx].syncStatus = .failed
                        }
                    }
                } catch {
                    cacheStore.logActivity(
                        eventType: .syncFailed,
                        filePath: item.originalPath,
                        filename: item.filename,
                        details: "Upload error: \(error.localizedDescription)",
                        sourceId: item.sourceId
                    )
                    if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                        fileItems[idx].syncStatus = .failed
                    }
                }
                
                self.syncProgress = Double(uploadedCount + index + 1) / Double(total)
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            await MainActor.run {
                for i in 0..<self.fileItems.count {
                    if self.fileItems[i].isDirectory {
                        self.fileItems[i].syncStatus = LocalFileScanner.shared.evaluateFolderSyncStatus(folderPath: self.fileItems[i].originalPath)
                    }
                }
                self.isSyncing = false
                self.syncProgress = 1.0
                self.syncSpeedMBs = 0.0
                self.syncStatusMessage = "Committed \(uploadedCount) files in \(String(format: "%.1f", elapsed))s"
            }
            
            cacheStore.logActivity(
                eventType: .syncCompleted,
                details: "Committed \(uploadedCount) files in \(String(format: "%.1f", elapsed))s",
                sourceId: toSync.first?.sourceId
            )
            loadRecentActivities()
            
            // Native macOS notification
            notify(title: "Synaps NAS Sync", message: "Successfully synced \(uploadedCount) files to NAS Vault.")
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
        let script = "display notification \"\(message)\" with title \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
