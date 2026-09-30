import Foundation

public final class LocalFileScanner {
    public static let shared = LocalFileScanner()
    private let cacheStore = LocalCacheStore.shared
    private let hashQueue = DispatchQueue(label: "com.synaps.hashqueue", qos: .utility)
    
    private let ignoreFiles: Set<String> = [
        ".ds_store", ".localized", ".git", "node_modules",
        "__pycache__", ".venv", "venv", ".next", ".cache"
    ]
    
    private let ignoreExtensions: Set<String> = [
        "tmp", "download", "part", "crdownload"
    ]
    
    public var onItemsHashed: (([SynapsFileItem]) -> Void)?
    
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
                    includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: [])
                    return
                }
                
                var itemsNeedingHash: [SynapsFileItem] = []
                
                for fileURL in urls {
                    let filename = fileURL.lastPathComponent
                    let ext = fileURL.pathExtension.lowercased()
                    
                    if self.ignoreFiles.contains(filename.lowercased()) || self.ignoreExtensions.contains(ext) {
                        continue
                    }
                    
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey]) else {
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
                        // Directory item
                        let dirItem = SynapsFileItem(
                            id: path,
                            originalPath: path,
                            filename: filename,
                            fileSize: 0,
                            sourceLocation: sourceLocation,
                            modifiedAt: mtime,
                            createdAt: ctime,
                            sha256: nil,
                            syncStatus: .uncommitted,
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
                        if cached.size == size && abs(cached.mtime - mtime.timeIntervalSince1970) < 0.05 {
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
                
                // Compute hashes asynchronously one-by-one in background with autoreleasepool
                if !itemsNeedingHash.isEmpty {
                    self.hashQueue.async {
                        var newlyHashed: [SynapsFileItem] = []
                        for item in itemsNeedingHash {
                            autoreleasepool {
                                if let sha = HashEngine.computeSHA256(for: item.originalPath) {
                                    let stat = (try? fileManager.attributesOfItem(atPath: item.originalPath))
                                    let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
                                    let cached = self.cacheStore.getRecord(for: item.originalPath)
                                    let currentStatus = cached?.syncStatus ?? SyncStatus.uncommitted.rawValue
                                    self.cacheStore.saveRecord(LocalCacheStore.CachedRecord(
                                        path: item.originalPath,
                                        inode: inode,
                                        size: item.fileSize,
                                        mtime: item.modifiedAt.timeIntervalSince1970,
                                        sha256: sha,
                                        lastSyncedAt: cached?.lastSyncedAt,
                                        syncStatus: currentStatus,
                                        album: item.albumName,
                                        isFavorite: item.isFavorite
                                    ))
                                    
                                    var updatedItem = item
                                    updatedItem.sha256 = sha
                                    if currentStatus == SyncStatus.committed.rawValue {
                                        updatedItem.syncStatus = .committed
                                    }
                                    newlyHashed.append(updatedItem)
                                }
                            }
                        }
                        
                        if !newlyHashed.isEmpty {
                            DispatchQueue.main.async {
                                self.onItemsHashed?(newlyHashed)
                            }
                        }
                    }
                }
            }
        }
    }
    
    public func scanDirectoryRecursively(
        directoryPath: String,
        sourceLocation: String,
        sourceId: String = "mac_harsh"
    ) -> [SynapsFileItem] {
        var results: [SynapsFileItem] = []
        let fileManager = FileManager.default
        let url = SecurityBookmarkManager.shared.startAccessing(path: directoryPath)
        defer { SecurityBookmarkManager.shared.stopAccessing(path: directoryPath) }
        
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            let ext = fileURL.pathExtension.lowercased()
            
            if self.ignoreFiles.contains(filename.lowercased()) || self.ignoreExtensions.contains(ext) {
                continue
            }
            
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isDirectoryKey]),
                  let isDir = resourceValues.isDirectory else {
                continue
            }
            
            if isDir {
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
            
            if let cached = self.cacheStore.getRecord(for: path) {
                if cached.size == size && abs(cached.mtime - mtime.timeIntervalSince1970) < 0.05 {
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
}
