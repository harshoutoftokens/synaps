import Foundation

public final class LocalFileScanner: @unchecked Sendable {
    public static let shared = LocalFileScanner()
    private let cacheStore: LocalCacheStore
    
    /// Background hashing for the most recently scanned folder; superseded by the next scan so
    /// navigating away from a folder full of large videos doesn't keep the disk busy.
    private var hashTask: Task<Void, Never>?
    private let hashTaskLock = NSLock()
    
    private let ignoreFiles: Set<String> = [
        ".ds_store", ".localized", ".git", "node_modules",
        "__pycache__", ".venv", "venv", ".next", ".cache"
    ]
    
    private let ignoreExtensions: Set<String> = [
        "tmp", "download", "part", "crdownload"
    ]
    
    private static let resourceKeys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey]
    
    /// Called on the main queue with batches of newly hashed items.
    public var onItemsHashed: (([SynapsFileItem]) -> Void)?
    
    init(cacheStore: LocalCacheStore = .shared) {
        self.cacheStore = cacheStore
    }
    
    private func isIgnored(name: String, ext: String) -> Bool {
        return ignoreFiles.contains(name.lowercased()) || ignoreExtensions.contains(ext)
    }
    
    public func scanDirectory(
        directoryPath: String,
        sourceLocation: String,
        sourceId: String = "mac_harsh"
    ) async -> [SynapsFileItem] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var results: [SynapsFileItem] = []
                let fileManager = FileManager.default
                let url = SecurityBookmarkManager.shared.startAccessing(path: directoryPath)
                defer { SecurityBookmarkManager.shared.stopAccessing(path: directoryPath) }
                
                // Shallow listing (immediate directory contents only, matching native Finder behavior)
                guard let urls = try? fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: Self.resourceKeys,
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: [])
                    return
                }
                
                var itemsNeedingHash: [SynapsFileItem] = []
                
                for fileURL in urls {
                    let filename = fileURL.lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()
                    
                    if self.isIgnored(name: filename, ext: ext) {
                        continue
                    }
                    
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(Self.resourceKeys)) else {
                        continue
                    }
                    
                    let isDir = resourceValues.isDirectory ?? false
                    let path = fileURL.path
                    let size = isDir ? 0 : Int64(resourceValues.fileSize ?? 0)
                    let mtime = resourceValues.contentModificationDate ?? Date()
                    let ctime = resourceValues.creationDate ?? mtime
                    
                    var fileSHA: String? = nil
                    var syncStatus: SyncStatus = .uncommitted
                    var isFav = false
                    var album: String? = nil
                    
                    if isDir {
                        let folderStatus = self.evaluateFolderSyncStatus(folderPath: path)
                        let dirItem = SynapsFileItem(
                            id: path,
                            originalPath: path,
                            filename: filename,
                            fileSize: 0,
                            sourceLocation: sourceLocation,
                            modifiedAt: mtime,
                            createdAt: ctime,
                            sha256: nil,
                            syncStatus: folderStatus,
                            isDirectory: true,
                            isFavorite: false,
                            albumName: nil,
                            sourceId: sourceId,
                            isLivePhotoVideo: false
                        )
                        results.append(dirItem)
                        continue
                    }
                    
                    // Fast cache check: sub-millisecond lookup
                    if let cached = self.cacheStore.getRecord(for: path) {
                        if cached.size == size && abs(cached.mtime - mtime.timeIntervalSince1970) < 1.0 {
                            fileSHA = cached.sha256
                            if cached.lastSyncedAt != nil || cached.syncStatus == SyncStatus.committed.rawValue {
                                syncStatus = .committed
                            }
                            isFav = cached.isFavorite
                            album = cached.album
                        }
                    }
                    
                    let item = SynapsFileItem(
                        id: path,
                        originalPath: path,
                        filename: filename,
                        fileSize: size,
                        sourceLocation: sourceLocation,
                        modifiedAt: mtime,
                        createdAt: ctime,
                        sha256: fileSHA,
                        syncStatus: syncStatus,
                        isDirectory: false,
                        isFavorite: isFav,
                        albumName: album,
                        sourceId: sourceId,
                        isLivePhotoVideo: ext == "mov" && fileManager.fileExists(atPath: fileURL.deletingPathExtension().appendingPathExtension("heic").path)
                    )
                    
                    results.append(item)
                    
                    if fileSHA == nil {
                        itemsNeedingHash.append(item)
                    }
                }
                
                // Natural alphabetical ordering matching Finder defaults
                results.sort {
                    $0.filename.localizedStandardCompare($1.filename) == .orderedAscending
                }
                
                // Return immediate results to UI in < 0.05 seconds!
                continuation.resume(returning: results)
                
                // Hash in the background (replacing any hashing still running for a previous folder)
                self.scheduleHashing(itemsNeedingHash)
            }
        }
    }
    
    // MARK: - Background hashing
    
    private func scheduleHashing(_ items: [SynapsFileItem]) {
        hashTaskLock.lock()
        defer { hashTaskLock.unlock() }
        hashTask?.cancel()
        hashTask = nil
        guard !items.isEmpty else { return }
        hashTask = Task.detached(priority: .utility) { [weak self] in
            await self?.hashItems(items)
        }
    }
    
    /// Stops background hashing (e.g. when switching to the NAS or iPhone views).
    public func cancelBackgroundHashing() {
        scheduleHashing([])
    }
    
    private func hashItems(_ items: [SynapsFileItem]) async {
        let byPath = Dictionary(items.map { ($0.originalPath, $0) }, uniquingKeysWith: { first, _ in first })
        let batcher = HashResultBatcher { [weak self] batch in
            guard let scanner = self else { return }
            DispatchQueue.main.async {
                scanner.onItemsHashed?(batch)
            }
        }
        _ = await HashEngine.computeSHA256s(for: items.map { $0.originalPath }) { [weak self] path, sha in
            guard let self = self, let sha = sha, let item = byPath[path], !Task.isCancelled else { return }
            batcher.add(self.persistHash(sha, for: item))
        }
        if !Task.isCancelled {
            batcher.flush()
        }
    }
    
    /// Saves a freshly computed hash. A previously committed status only carries over when the
    /// record describes the same content (same hash, or same size+mtime if no hash was stored);
    /// an edited file must show up as uncommitted again.
    private func persistHash(_ sha: String, for item: SynapsFileItem) -> SynapsFileItem {
        let mtime = item.modifiedAt.timeIntervalSince1970
        let stat = try? FileManager.default.attributesOfItem(atPath: item.originalPath)
        let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        let cached = cacheStore.getRecord(for: item.originalPath)
        
        var sameContent = false
        if let cached = cached {
            if let oldSha = cached.sha256 {
                sameContent = oldSha == sha
            } else {
                sameContent = cached.size == item.fileSize && abs(cached.mtime - mtime) < 1.0
            }
        }
        let status = sameContent ? (cached?.syncStatus ?? SyncStatus.uncommitted.rawValue) : SyncStatus.uncommitted.rawValue
        
        cacheStore.saveRecord(LocalCacheStore.CachedRecord(
            path: item.originalPath,
            inode: inode,
            size: item.fileSize,
            mtime: mtime,
            sha256: sha,
            lastSyncedAt: sameContent ? cached?.lastSyncedAt : nil,
            syncStatus: status,
            album: item.albumName,
            isFavorite: item.isFavorite
        ))
        
        var updatedItem = item
        updatedItem.sha256 = sha
        if status == SyncStatus.committed.rawValue || (sameContent && cached?.lastSyncedAt != nil) {
            updatedItem.syncStatus = .committed
        }
        return updatedItem
    }
    
    // MARK: - Recursive scans
    
    public func scanDirectoryRecursively(
        directoryPath: String,
        sourceLocation: String,
        sourceId: String = "mac_harsh"
    ) -> [SynapsFileItem] {
        var results: [SynapsFileItem] = []
        let fileManager = FileManager.default
        let url = SecurityBookmarkManager.shared.startAccessing(path: directoryPath)
        defer { SecurityBookmarkManager.shared.stopAccessing(path: directoryPath) }
        
        let keys = CacheKeyMapper(root: url.path)
        let records = cacheStore.records(under: url.path)
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            
            guard let resourceValues = try? fileURL.resourceValues(forKeys: Set(Self.resourceKeys)),
                  let isDir = resourceValues.isDirectory else {
                continue
            }
            
            if isDir {
                // Don't descend into node_modules, venv, ... (matches the Python client)
                if ignoreFiles.contains(filename.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            if isIgnored(name: filename, ext: ext) {
                continue
            }
            
            let path = fileURL.path
            let size = Int64(resourceValues.fileSize ?? 0)
            let mtime = resourceValues.contentModificationDate ?? Date()
            let ctime = resourceValues.creationDate ?? mtime
            
            var fileSHA: String? = nil
            var syncStatus: SyncStatus = .uncommitted
            var isFav = false
            var album: String? = nil
            
            if let cached = records[keys.cacheKey(for: path)] {
                if cached.size == size && abs(cached.mtime - mtime.timeIntervalSince1970) < 1.0 {
                    fileSHA = cached.sha256
                    if cached.lastSyncedAt != nil || cached.syncStatus == SyncStatus.committed.rawValue {
                        syncStatus = .committed
                    }
                    isFav = cached.isFavorite
                    album = cached.album
                }
            }
            
            let item = SynapsFileItem(
                id: path,
                originalPath: path,
                filename: filename,
                fileSize: size,
                sourceLocation: sourceLocation,
                modifiedAt: mtime,
                createdAt: ctime,
                sha256: fileSHA,
                syncStatus: syncStatus,
                isDirectory: false,
                isFavorite: isFav,
                albumName: album,
                sourceId: sourceId,
                isLivePhotoVideo: ext == "mov" && fileManager.fileExists(atPath: fileURL.deletingPathExtension().appendingPathExtension("heic").path)
            )
            results.append(item)
        }
        
        return results
    }
    
    /// Off-main wrapper: recursive enumeration of a large tree must not block the UI.
    public func scanDirectoryRecursivelyAsync(
        directoryPath: String,
        sourceLocation: String,
        sourceId: String = "mac_harsh"
    ) async -> [SynapsFileItem] {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: self.scanDirectoryRecursively(
                    directoryPath: directoryPath,
                    sourceLocation: sourceLocation,
                    sourceId: sourceId
                ))
            }
        }
    }
    
    public func evaluateFolderSyncStatus(folderPath: String) -> SyncStatus {
        let url = SecurityBookmarkManager.shared.startAccessing(path: folderPath)
        defer { SecurityBookmarkManager.shared.stopAccessing(path: folderPath) }
        
        let keys = CacheKeyMapper(root: url.path)
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .uncommitted
        }
        
        // Most folders contain an uncommitted file early on, so start with per-file lookups and only
        // load every record under the folder (one range query) once the folder looks committed.
        var records: [String: LocalCacheStore.CachedRecord]? = nil
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            
            let filename = fileURL.lastPathComponent
            if rv.isDirectory ?? false {
                if ignoreFiles.contains(filename.lowercased()) {
                    enumerator.skipDescendants()
                }
                continue
            }
            
            let ext = fileURL.pathExtension.lowercased()
            if isIgnored(name: filename, ext: ext) {
                continue
            }
            
            fileCount += 1
            if fileCount == 64 && records == nil {
                records = cacheStore.records(under: url.path)
            }
            let p = fileURL.path
            let size = Int64(rv.fileSize ?? 0)
            let mtime = (rv.contentModificationDate ?? Date()).timeIntervalSince1970
            
            let record = records?[keys.cacheKey(for: p)] ?? cacheStore.getRecord(for: p)
            guard let record = record, record.isCommitted(size: size, mtime: mtime) else {
                return .uncommitted
            }
        }
        
        return fileCount > 0 ? .committed : .uncommitted
    }
    
    /// Evaluates many folders off the main thread.
    public func evaluateFolderSyncStatuses(folderPaths: [String]) async -> [String: SyncStatus] {
        guard !folderPaths.isEmpty else { return [:] }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var result: [String: SyncStatus] = [:]
                for path in folderPaths {
                    result[path] = self.evaluateFolderSyncStatus(folderPath: path)
                }
                continuation.resume(returning: result)
            }
        }
    }
}

/// FileManager reports children under the fully resolved root ("/private/var/..."), while cache keys
/// come from `LocalCacheStore.normalizePath` ("/var/..."), so a folder reached through a symlink
/// would never match a bulk-loaded record. Maps enumerated paths onto cache keys by root prefix.
private struct CacheKeyMapper {
    private let enumeratedRoot: String
    private let normalizedRoot: String
    
    init(root: String) {
        var resolved = root
        if let real = realpath(root, nil) {
            resolved = String(cString: real)
            free(real)
        }
        enumeratedRoot = resolved.hasSuffix("/") ? resolved : resolved + "/"
        let normalized = LocalCacheStore.normalizePath(root)
        normalizedRoot = normalized.hasSuffix("/") ? normalized : normalized + "/"
    }
    
    func cacheKey(for enumeratedPath: String) -> String {
        if enumeratedPath.hasPrefix(enumeratedRoot) {
            return normalizedRoot + enumeratedPath.dropFirst(enumeratedRoot.count)
        }
        return LocalCacheStore.normalizePath(enumeratedPath)
    }
}

/// Collects hashed items and hands them to the UI in batches (at most ~0.75 s latency) instead of
/// once per file or only after the whole folder is done.
private final class HashResultBatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [SynapsFileItem] = []
    private var flushScheduled = false
    private let deliver: ([SynapsFileItem]) -> Void
    private let maxBatch = 32
    private let maxDelay: TimeInterval = 0.75
    
    init(deliver: @escaping ([SynapsFileItem]) -> Void) {
        self.deliver = deliver
    }
    
    func add(_ item: SynapsFileItem) {
        lock.lock()
        pending.append(item)
        let shouldFlushNow = pending.count >= maxBatch
        let shouldSchedule = !shouldFlushNow && !flushScheduled
        if shouldSchedule {
            flushScheduled = true
        }
        lock.unlock()
        
        if shouldFlushNow {
            flush()
        } else if shouldSchedule {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + maxDelay) { [weak self] in
                self?.flush()
            }
        }
    }
    
    func flush() {
        lock.lock()
        let batch = pending
        pending.removeAll()
        flushScheduled = false
        lock.unlock()
        if !batch.isEmpty {
            deliver(batch)
        }
    }
}
