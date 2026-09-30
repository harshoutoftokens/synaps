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
    @Published public var searchQuery: String = ""
    @Published public var filterSelection: FilterOption = .all
    @Published public var sortField: SortField = .name
    @Published public var sortAscending: Bool = true
    @Published public var selectedItemIds: Set<String> = []
    @Published public var recentActivities: [SyncActivityItem] = []
    @Published public var showActivityLog: Bool = false
    
    public var isPicturesSection: Bool {
        selectedSidebarItem?.id == "section_pictures" || selectedSidebarItem?.isPhone == true
    }
    
    public enum SortField: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateModified = "Date Modified"
        case dateCreated = "Date Created"
        case size = "Size"
        case kind = "Kind"
        
        public var id: String { rawValue }
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
    public let phoneManager = iPhoneManager.shared
    
    private var cancellables = Set<AnyCancellable>()
    
    public init() {
        setupPhoneObserver()
        setupScannerObserver()
        Task {
            await checkNASStatus()
            loadDefaultFolder()
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
                
                await self.runPreCheckDeduplication(
                    items: hashedItems,
                    sourceId: self.selectedSidebarItem?.sourceId ?? "mac_harsh"
                )
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
                let extA = (a.filename as NSString).pathExtension.lowercased()
                let extB = (b.filename as NSString).pathExtension.lowercased()
                if extA.isEmpty && !extB.isEmpty {
                    comparison = .orderedDescending
                } else if !extA.isEmpty && extB.isEmpty {
                    comparison = .orderedAscending
                } else if extA == extB {
                    comparison = a.filename.localizedStandardCompare(b.filename)
                } else {
                    comparison = extA.localizedStandardCompare(extB)
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
        let online = await nasClient.checkHealth()
        let wasOffline = !self.nasOnline
        self.nasOnline = online
        if online && wasOffline && !self.fileItems.isEmpty {
            await runPreCheckDeduplication(items: self.fileItems, sourceId: selectedSidebarItem?.sourceId ?? "mac_harsh")
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
        }
    }
    
    public func importAllItems() {
        let filenames = filteredItems.map { $0.filename }
        Task {
            await phoneManager.importItems(filenames: filenames)
            self.selectedItemIds.removeAll()
        }
    }
    
    public func navigateIntoFolder(path: String, title: String, sourceId: String) {
        if !currentFolderPath.isEmpty {
            navigationHistory.append(currentFolderPath)
        }
        loadFolder(path: path, sourceLocation: title, sourceId: sourceId)
    }
    
    public func navigateBack() {
        guard let prev = navigationHistory.popLast() else { return }
        let title = (prev as NSString).lastPathComponent
        loadFolder(path: prev, sourceLocation: title, sourceId: selectedSidebarItem?.sourceId ?? "mac_harsh")
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
            self.fileItems = items
            self.isLoading = false
            
            // Run pre-check deduplication in background to instantly update badges from NAS
            await runPreCheckDeduplication(items: items, sourceId: sourceId)
        }
    }
    
    public func runPreCheckDeduplication(items: [SynapsFileItem], sourceId: String) async {
        guard nasOnline else { return }
        let uncommitted = items.filter { !$0.isDirectory && $0.syncStatus == .uncommitted && $0.sha256 != nil }
        guard !uncommitted.isEmpty else { return }
        
        do {
            let res = try await nasClient.batchPreCheck(
                sourceId: sourceId,
                friendlyName: "Harsh's Mac",
                platform: "macOS",
                items: uncommitted
            )
            
            let dedupPaths = Set(res.results.filter { $0.status == "dedup_linked" }.map { $0.original_path })
            if !dedupPaths.isEmpty {
                cacheStore.markSynced(paths: Array(dedupPaths), status: .committed)
                
                for p in dedupPaths {
                    let fn = (p as NSString).lastPathComponent
                    cacheStore.logActivity(
                        eventType: .existingDiscovered,
                        filePath: p,
                        filename: fn,
                        details: "Existing file detected on NAS (SHA-256 match)",
                        sourceId: sourceId
                    )
                }
                loadRecentActivities()
                
                // Update local fileItems state
                for i in 0..<fileItems.count {
                    if dedupPaths.contains(fileItems[i].originalPath) {
                        fileItems[i].syncStatus = .committed
                    }
                }
            }
        } catch {
            print("Pre-check error: \(error.localizedDescription)")
        }
    }
    
    public func syncAllUncommitted() {
        guard !isSyncing else { return }
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
        if item.isDirectory {
            let files = LocalFileScanner.shared.scanDirectoryRecursively(
                directoryPath: item.originalPath,
                sourceLocation: item.sourceLocation,
                sourceId: item.sourceId
            ).filter { $0.syncStatus != .committed }
            guard !files.isEmpty else {
                syncStatusMessage = "All files in folder are already committed"
                return
            }
            startSyncProcess(for: files, title: "Syncing folder \(item.filename)")
        } else {
            startSyncProcess(for: [item], title: "Syncing \(item.filename)")
        }
    }
    
    public func syncSelectedItems() {
        guard !isSyncing else { return }
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
                        friendlyName: "MacBook",
                        platform: "macOS",
                        items: itemsWithSha
                    )
                    
                    var dedupPaths = Set<String>()
                    for res in precheckResp.results {
                        if res.status == "dedup_linked" {
                            dedupPaths.insert(res.original_path)
                            cacheStore.markSynced(paths: [res.original_path], status: .committed)
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
                        
                        cacheStore.markSynced(paths: [item.originalPath], status: .committed)
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
            self.isSyncing = false
            self.syncProgress = 1.0
            self.syncSpeedMBs = 0.0
            self.syncStatusMessage = "Committed \(uploadedCount) files in \(String(format: "%.1f", elapsed))s"
            
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
