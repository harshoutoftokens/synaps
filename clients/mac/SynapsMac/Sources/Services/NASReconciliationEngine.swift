import Foundation

/// Service responsible for reconciling local file sync states against the authoritative NAS state.
///
/// Implements a multi-tier reconciliation architecture:
/// 1. Fast Tier: High-speed metadata comparison against the NAS filesystem mirror (`/api/finder/browse`),
///    instantly validating pre-existing files by filename and size with 0 local hashing cost.
/// 2. Deep Tier: Hash-based provenance verification against the NAS vault (`/api/v2/ingest/check`),
///    identifying deduplicated files across devices, renamed items, or files synced prior to client setup.
/// 3. Authoritative sync status enforcement: Genuine non-existent or deleted NAS items remain/revert to uncommitted.
public final class NASReconciliationEngine {
    public static let shared = NASReconciliationEngine()
    
    private let nasClient: NASClient
    private let cacheStore: LocalCacheStore
    
    public init(nasClient: NASClient = .shared, cacheStore: LocalCacheStore = .shared) {
        self.nasClient = nasClient
        self.cacheStore = cacheStore
    }
    
    /// Resolves a local directory path to its authoritative NAS mirror directory.
    /// Example: "/Users/harshrathod/Downloads" -> "Mirrors/Harsh/Mac/Downloads"
    /// Example: "/Users/harshrathod/Downloads/01_Netflix_Logo" -> "Mirrors/Harsh/Mac/Downloads/01_Netflix_Logo"
    /// Example: "/Users/harshrathod/Desktop" -> "Mirrors/Harsh/Mac/Desktop"
    public static func resolveMirrorPath(for directoryPath: String, sourceLocation: String = "") -> String {
        let clean = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = clean.components(separatedBy: "/").filter { !$0.isEmpty }
        
        // Strip "/Users/<username>/" to obtain the relative folder path
        if components.count >= 2 && components[0] == "Users" {
            let relComponents = components.dropFirst(2)
            if !relComponents.isEmpty {
                let relPath = relComponents.joined(separator: "/")
                return "Mirrors/Harsh/Mac/\(relPath)"
            }
        }
        
        if !sourceLocation.isEmpty && !sourceLocation.contains("/") {
            return "Mirrors/Harsh/Mac/\(sourceLocation)"
        }
        
        let trimmedRel = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "Mirrors/Harsh/Mac/\(trimmedRel)"
    }
    
    /// Reconciles a list of local directory items against the authoritative NAS state.
    /// Executes Fast Tier metadata matching followed by Deep Tier hash checking for unmatched items.
    public func reconcileDirectory(
        directoryPath: String,
        sourceLocation: String,
        localItems: [SynapsFileItem],
        sourceId: String = "mac_harsh"
    ) async -> [SynapsFileItem] {
        var updatedItems = localItems
        let mirrorPath = Self.resolveMirrorPath(for: directoryPath, sourceLocation: sourceLocation)
        
        // 1. Fetch remote files in the mirrored directory from the authoritative NAS
        var remoteFilesByName: [String: Int64] = [:]
        do {
            let remoteFiles = try await nasClient.browseAllDirectoryFiles(path: mirrorPath)
            for rf in remoteFiles {
                remoteFilesByName[rf.name] = rf.size
            }
        } catch {
            print("⚠️ [NASReconciliation] Could not query mirror path \(mirrorPath): \(error.localizedDescription)")
            return localItems
        }
        
        var itemsNeedingDeepCheck: [SynapsFileItem] = []
        
        // 2. Fast Tier: match filename + file size against remote mirror
        for i in 0..<updatedItems.count {
            if updatedItems[i].isDirectory {
                continue
            }
            
            let filename = updatedItems[i].filename
            let localSize = updatedItems[i].fileSize
            
            if let remoteSize = remoteFilesByName[filename], remoteSize == localSize {
                // Exact match on authoritative NAS mirror!
                if updatedItems[i].syncStatus != .committed {
                    updatedItems[i].syncStatus = .committed
                    cacheStore.recordItemSynced(
                        path: updatedItems[i].originalPath,
                        fileSize: localSize,
                        modifiedAt: updatedItems[i].modifiedAt,
                        sha256: updatedItems[i].sha256,
                        album: updatedItems[i].albumName,
                        isFavorite: updatedItems[i].isFavorite
                    )
                    cacheStore.logActivity(
                        eventType: .existingDiscovered,
                        filePath: updatedItems[i].originalPath,
                        filename: filename,
                        details: "Verified in NAS mirror (metadata match)",
                        sourceId: sourceId
                    )
                }
            } else {
                // Not in NAS mirror directory at this path.
                // It could exist in the vault (cross-device, renamed, or legacy) OR genuinely uncommitted.
                if updatedItems[i].sha256 != nil {
                    itemsNeedingDeepCheck.append(updatedItems[i])
                } else {
                    // Stale cache invalidation: if local cache claimed committed, but NAS mirror doesn't have it
                    // and no hash exists to prove it is in vault, revert to uncommitted.
                    if updatedItems[i].syncStatus == .committed {
                        updatedItems[i].syncStatus = .uncommitted
                        cacheStore.updateSyncStatus(path: updatedItems[i].originalPath, status: .uncommitted)
                    }
                }
            }
        }
        
        // 3. Deep Tier: check SHA-256 deduplication against the NAS vault
        if !itemsNeedingDeepCheck.isEmpty {
            updatedItems = await performDedupCheck(
                candidates: itemsNeedingDeepCheck,
                allCurrentItems: updatedItems,
                sourceId: sourceId
            )
        }
        
        // 4. Re-evaluate folder sync statuses for any subdirectories
        for i in 0..<updatedItems.count {
            if updatedItems[i].isDirectory {
                updatedItems[i].syncStatus = LocalFileScanner.shared.evaluateFolderSyncStatus(folderPath: updatedItems[i].originalPath)
            }
        }
        
        return updatedItems
    }
    
    /// Reconciles items when their background SHA-256 hashes become available.
    public func reconcileHashedItems(
        hashedItems: [SynapsFileItem],
        currentFileItems: [SynapsFileItem],
        sourceId: String = "mac_harsh"
    ) async -> [SynapsFileItem] {
        let uncommittedCandidates = hashedItems.filter { !$0.isDirectory && $0.syncStatus != .committed && $0.sha256 != nil }
        guard !uncommittedCandidates.isEmpty else { return currentFileItems }
        
        return await performDedupCheck(
            candidates: uncommittedCandidates,
            allCurrentItems: currentFileItems,
            sourceId: sourceId
        )
    }
    
    /// Batch checks SHA-256 hashes against NAS /api/v2/ingest/check.
    /// If dedup_linked, marks as .committed. If need_upload, ensures status is .uncommitted.
    private func performDedupCheck(
        candidates: [SynapsFileItem],
        allCurrentItems: [SynapsFileItem],
        sourceId: String
    ) async -> [SynapsFileItem] {
        var updated = allCurrentItems
        
        // Chunk candidates in batches of 100 to avoid overly large request payloads
        let chunkSize = 100
        for chunkStart in stride(from: 0, to: candidates.count, by: chunkSize) {
            let chunkEnd = min(chunkStart + chunkSize, candidates.count)
            let batch = Array(candidates[chunkStart..<chunkEnd])
            
            do {
                let res = try await nasClient.batchPreCheck(
                    sourceId: sourceId,
                    friendlyName: "Harsh's Mac",
                    platform: "macOS",
                    items: batch
                )
                
                let dedupPaths = Set(res.results.filter { $0.status == "dedup_linked" }.map { $0.original_path })
                let needUploadPaths = Set(res.results.filter { $0.status == "need_upload" }.map { $0.original_path })
                
                for item in batch {
                    let path = item.originalPath
                    if dedupPaths.contains(path) {
                        // Found in NAS vault!
                        cacheStore.recordItemSynced(
                            path: path,
                            fileSize: item.fileSize,
                            modifiedAt: item.modifiedAt,
                            sha256: item.sha256,
                            album: item.albumName,
                            isFavorite: item.isFavorite
                        )
                        cacheStore.logActivity(
                            eventType: .existingDiscovered,
                            filePath: path,
                            filename: item.filename,
                            details: "Existing file linked on NAS (SHA-256 match)",
                            sourceId: sourceId
                        )
                        if let idx = updated.firstIndex(where: { $0.originalPath == path }) {
                            updated[idx].syncStatus = .committed
                        }
                    } else if needUploadPaths.contains(path) {
                        // Genuinely not on NAS! Revert if previously cached as committed
                        cacheStore.updateSyncStatus(path: path, status: .uncommitted)
                        if let idx = updated.firstIndex(where: { $0.originalPath == path }) {
                            updated[idx].syncStatus = .uncommitted
                        }
                    }
                }
            } catch {
                print("⚠️ [NASReconciliation] Ingest pre-check batch failed: \(error.localizedDescription)")
            }
        }
        
        // Re-evaluate folder sync statuses after updating items
        for i in 0..<updated.count {
            if updated[i].isDirectory {
                updated[i].syncStatus = LocalFileScanner.shared.evaluateFolderSyncStatus(folderPath: updated[i].originalPath)
            }
        }
        
        return updated
    }
}
