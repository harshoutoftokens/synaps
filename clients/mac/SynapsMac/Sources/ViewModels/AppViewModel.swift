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
        Task {
            await checkNASStatus()
            loadDefaultFolder()
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
        self.nasOnline = online
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
    
    public func toggleSelection(id: String) {
        if selectedItemIds.contains(id) {
            selectedItemIds.remove(id)
        } else {
            selectedItemIds.insert(id)
        }
    }
    
    public func selectAll() {
        selectedItemIds = Set(filteredItems.map { $0.id })
    }
    
    public func deselectAll() {
        selectedItemIds.removeAll()
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
        
        isSyncing = true
        syncProgress = 0.0
        syncStatusMessage = "Starting sync of \(toSync.count) files..."
        
        Task {
            let total = toSync.count
            var uploadedCount = 0
            let startTime = Date()
            var totalBytesUploaded: Int64 = 0
            
            for (index, item) in toSync.enumerated() {
                self.syncStatusMessage = "[\(index + 1)/\(total)] Syncing \(item.filename)..."
                
                // Mark item as syncing
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
                        if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                            fileItems[idx].syncStatus = .committed
                        }
                    } else {
                        if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                            fileItems[idx].syncStatus = .failed
                        }
                    }
                } catch {
                    if let idx = fileItems.firstIndex(where: { $0.id == item.id }) {
                        fileItems[idx].syncStatus = .failed
                    }
                }
                
                self.syncProgress = Double(index + 1) / Double(total)
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            self.isSyncing = false
            self.syncProgress = 1.0
            self.syncSpeedMBs = 0.0
            self.syncStatusMessage = "Committed \(uploadedCount) files in \(String(format: "%.1f", elapsed))s"
            
            // Native macOS notification
            notify(title: "Synaps NAS Sync", message: "Successfully synced \(uploadedCount) files to NAS Vault.")
        }
    }
    
    private func notify(title: String, message: String) {
        let script = "display notification \"\(message)\" with title \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
