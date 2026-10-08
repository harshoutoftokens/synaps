import Foundation
import Combine
import Photos
import UIKit

public final class SyncManager: ObservableObject, @unchecked Sendable {
    public static let shared = SyncManager()
    
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var currentProgress: Double = 0.0
    @Published public private(set) var currentItemName: String = ""
    @Published public private(set) var syncedCount: Int = 0
    @Published public private(set) var totalToSyncCount: Int = 0
    @Published public private(set) var isConnectedToNAS: Bool = false
    
    private var syncTask: Task<Void, Never>?
    private var isCancelled = false
    private let queue = DispatchQueue(label: "com.synaps.ios.syncmanager", qos: .utility)
    
    private init() {
        Task {
            await checkNASStatus()
        }
    }
    
    public func checkNASStatus() async {
        let ok = await NASClient.shared.checkHealth()
        await MainActor.run {
            self.isConnectedToNAS = ok
        }
    }
    
    public func cancelSync() {
        isCancelled = true
        syncTask?.cancel()
        syncTask = nil
        Task { @MainActor in
            self.isSyncing = false
            self.currentItemName = ""
        }
    }
    
    /// Syncs an array of media items to the NAS (manual selection or all uncommitted).
    public func syncItems(_ items: [SynapsMediaItem]) {
        guard !items.isEmpty else { return }
        
        cancelSync()
        isCancelled = false
        
        syncTask = Task {
            await MainActor.run {
                self.isSyncing = true
                self.totalToSyncCount = items.count
                self.syncedCount = 0
                self.currentProgress = 0.0
            }
            
            // Check NAS health first
            let isOnline = await NASClient.shared.checkHealth()
            await MainActor.run {
                self.isConnectedToNAS = isOnline
            }
            
            guard isOnline else {
                LocalCacheStore.shared.logActivity(
                    eventType: .failed,
                    filePath: "",
                    filename: "Sync Failed",
                    details: "Cannot connect to Synaps NAS at \(NASClient.shared.getBaseUrl())"
                )
                await MainActor.run {
                    self.isSyncing = false
                }
                return
            }
            
            let cfg = SynapsConfig.load()
            var processed = 0
            
            // Batch pre-check in chunks of 50 items for high efficiency
            let chunkSize = 50
            for i in stride(from: 0, to: items.count, by: chunkSize) {
                if Task.isCancelled || self.isCancelled { break }
                
                let chunk = Array(items[i..<min(i + chunkSize, items.count)])
                await processBatch(chunk, cfg: cfg, processedSoFar: processed, totalCount: items.count)
                processed += chunk.count
            }
            
            await MainActor.run {
                self.isSyncing = false
                self.currentProgress = 1.0
                self.currentItemName = ""
            }
            
            // Refresh library items to reflect changes
            await PhotoLibraryService.shared.fetchAllMedia()
        }
    }
    
    private func processBatch(_ items: [SynapsMediaItem], cfg: SynapsConfig, processedSoFar: Int, totalCount: Int) async {
        // Step 1: Compute hashes for any items missing SHA-256
        var preparedItems: [SynapsMediaItem] = []
        for var item in items {
            if Task.isCancelled || self.isCancelled { return }
            
            await MainActor.run {
                self.currentItemName = "Hashing \(item.filename)..."
            }
            
            // Mark syncing in UI
            LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .syncing)
            
            if item.sha256 == nil {
                do {
                    let tempFile = try await PhotoLibraryService.shared.exportAssetToFile(localIdentifier: item.localIdentifier)
                    defer { try? FileManager.default.removeItem(at: tempFile) }
                    let sha = try HashEngine.shared.computeSHA256(for: tempFile)
                    item.sha256 = sha
                    LocalCacheStore.shared.upsertRecord(
                        id: item.id,
                        filename: item.filename,
                        size: item.fileSize,
                        mtime: item.modifiedAt.timeIntervalSince1970,
                        sha256: sha,
                        syncStatus: .syncing,
                        isFavorite: item.isFavorite
                    )
                } catch {
                    LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .failed)
                    LocalCacheStore.shared.logActivity(
                        eventType: .failed,
                        filePath: item.originalPath,
                        filename: item.filename,
                        details: "Failed to read/hash asset: \(error.localizedDescription)",
                        sourceId: cfg.sourceId
                    )
                    continue
                }
            }
            preparedItems.append(item)
        }
        
        guard !preparedItems.isEmpty else { return }
        
        // Step 2: Batch pre-check with NAS for fast deduplication
        var needUploadItems: [SynapsMediaItem] = []
        do {
            let checkResponse = try await NASClient.shared.batchPreCheck(
                sourceId: cfg.sourceId,
                friendlyName: cfg.friendlyName,
                items: preparedItems
            )
            
            let resultMap = Dictionary(uniqueKeysWithValues: checkResponse.results.map { ($0.original_path, $0) })
            
            for item in preparedItems {
                if let res = resultMap[item.originalPath] {
                    if res.status == "dedup_linked" {
                        // Already exists in NAS Vault! Instant commit with 0 network payload!
                        LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .committed, sha256: item.sha256)
                        LocalCacheStore.shared.logActivity(
                            eventType: .dedupLinked,
                            filePath: item.originalPath,
                            filename: item.filename,
                            details: "Deduplicated instantly with NAS physical object",
                            sourceId: cfg.sourceId
                        )
                        await MainActor.run {
                            self.syncedCount += 1
                            self.currentProgress = Double(self.syncedCount) / Double(max(1, totalCount))
                        }
                    } else {
                        needUploadItems.append(item)
                    }
                } else {
                    needUploadItems.append(item)
                }
            }
        } catch {
            // Fallback: upload all prepared items if batch pre-check errors
            needUploadItems = preparedItems
        }
        
        // Step 3: Upload files that need upload
        for item in needUploadItems {
            if Task.isCancelled || self.isCancelled { return }
            
            await MainActor.run {
                self.currentItemName = "Uploading \(item.filename)..."
            }
            
            do {
                let tempFile = try await PhotoLibraryService.shared.exportAssetToFile(localIdentifier: item.localIdentifier)
                defer { try? FileManager.default.removeItem(at: tempFile) }
                
                let ok = try await NASClient.shared.uploadMediaFile(fileURL: tempFile, item: item, sourceId: cfg.sourceId)
                if ok {
                    LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .committed, sha256: item.sha256)
                    LocalCacheStore.shared.logActivity(
                        eventType: .uploaded,
                        filePath: item.originalPath,
                        filename: item.filename,
                        details: "Uploaded successfully (\(item.formattedSize))",
                        sourceId: cfg.sourceId
                    )
                } else {
                    LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .failed)
                    LocalCacheStore.shared.logActivity(
                        eventType: .failed,
                        filePath: item.originalPath,
                        filename: item.filename,
                        details: "Upload rejected by NAS server",
                        sourceId: cfg.sourceId
                    )
                }
            } catch {
                LocalCacheStore.shared.updateSyncStatus(id: item.id, status: .failed)
                LocalCacheStore.shared.logActivity(
                    eventType: .failed,
                    filePath: item.originalPath,
                    filename: item.filename,
                    details: "Upload error: \(error.localizedDescription)",
                    sourceId: cfg.sourceId
                )
            }
            
            await MainActor.run {
                self.syncedCount += 1
                self.currentProgress = Double(self.syncedCount) / Double(max(1, totalCount))
            }
        }
    }
}
