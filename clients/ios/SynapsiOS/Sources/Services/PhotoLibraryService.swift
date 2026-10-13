import Foundation
import Photos
import UIKit
import AVFoundation
import Combine

/// Thread-safe localIdentifier -> PHAsset map from the latest library fetch, so thumbnail and
/// export requests don't run a Photos database query (fetchAssets(withLocalIdentifiers:)) each.
public final class AssetIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var assets: [String: PHAsset] = [:]
    private var _fetchResult: PHFetchResult<PHAsset>?
    
    public func replace(_ newAssets: [String: PHAsset], fetchResult: PHFetchResult<PHAsset>) {
        lock.lock()
        assets = newAssets
        _fetchResult = fetchResult
        lock.unlock()
    }
    
    public var fetchResult: PHFetchResult<PHAsset>? {
        lock.lock()
        defer { lock.unlock() }
        return _fetchResult
    }
    
    /// Falls back to a PhotoKit lookup for assets added since the last fetch (e.g. background launch).
    public func asset(for id: String) -> PHAsset? {
        lock.lock()
        let cached = assets[id]
        lock.unlock()
        if let cached {
            return cached
        }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }
}

/// Carries a PhotoKit callback result back to the main actor.
final class PlayerItemBox: @unchecked Sendable {
    let item: AVPlayerItem?
    init(_ item: AVPlayerItem?) {
        self.item = item
    }
}

extension PHAsset {
    /// Modification time used to key cached resource scans and hashes.
    var synapsMtime: Double {
        (modificationDate ?? creationDate ?? .distantPast).timeIntervalSince1970
    }
}

/// Maps an asset's PhotoKit resources to the parts Synaps uploads.
public enum PartScanner {
    public static func scan(_ asset: PHAsset) -> LocalCacheStore.ResourceScan {
        let id = asset.localIdentifier
        var byKind: [AssetPartKind: PHAssetResource] = [:]
        for resource in PHAssetResource.assetResources(for: asset) {
            if let kind = AssetPartKind(resourceType: resource.type), byKind[kind] == nil {
                byKind[kind] = resource
            }
        }
        
        // Same primary choice as v1 (original photo / video) so existing NAS paths stay stable.
        let preferred: [AssetPartKind]
        switch asset.mediaType {
        case .video: preferred = [.video, .fullSizeVideo]
        case .audio: preferred = [.audio]
        default: preferred = [.photo, .alternatePhoto, .fullSizePhoto]
        }
        let order: [AssetPartKind] = [.photo, .video, .audio, .alternatePhoto, .pairedVideo, .fullSizePhoto, .fullSizeVideo, .fullSizePairedVideo]
        guard let primaryKind = preferred.first(where: { byKind[$0] != nil }) ?? order.first(where: { byKind[$0] != nil }),
              let primaryResource = byKind[primaryKind] else {
            return LocalCacheStore.ResourceScan(assetId: id, mtime: asset.synapsMtime, isFavorite: asset.isFavorite, parts: [])
        }
        
        let fallbackExt = asset.mediaType == .video ? "MOV" : "JPG"
        let primaryName = nonEmpty(primaryResource.originalFilename) ?? "IMG_\(id.prefix(8)).\(fallbackExt)"
        let primaryBase = (primaryName as NSString).deletingPathExtension
        let primaryExt = (primaryName as NSString).pathExtension
        
        var parts: [AssetPart] = []
        var usedNames = Set<String>()
        for kind in [primaryKind] + order where kind == primaryKind || byKind[kind] != nil {
            guard let resource = byKind[kind], !parts.contains(where: { $0.kind == kind }) else { continue }
            var name: String
            if kind == primaryKind {
                name = primaryName
            } else if kind.isEdit {
                name = editedName(primaryBase: primaryBase, primaryExt: primaryExt, renderName: resource.originalFilename)
            } else {
                name = nonEmpty(resource.originalFilename) ?? "\(primaryBase).\(kind == .pairedVideo ? "MOV" : primaryExt)"
            }
            if usedNames.contains(name.lowercased()) {
                let ns = name as NSString
                name = "\(ns.deletingPathExtension)_\(kind.rawValue).\(ns.pathExtension)"
            }
            usedNames.insert(name.lowercased())
            parts.append(AssetPart(assetId: id, kind: kind, filename: name, size: fileSize(of: resource), isPrimary: kind == primaryKind))
        }
        return LocalCacheStore.ResourceScan(assetId: id, mtime: asset.synapsMtime, isFavorite: asset.isFavorite, parts: parts)
    }
    
    /// Apple's own naming for edited exports: IMG_1234.HEIC -> IMG_E1234.<render ext>.
    static func editedName(primaryBase: String, primaryExt: String, renderName: String) -> String {
        var ext = (renderName as NSString).pathExtension
        if ext.isEmpty { ext = primaryExt }
        if primaryExt == primaryExt.uppercased() { ext = ext.uppercased() }
        if primaryBase.uppercased().hasPrefix("IMG_") {
            return "IMG_E\(primaryBase.dropFirst(4)).\(ext)"
        }
        return "\(primaryBase)_edited.\(ext)"
    }
    
    /// PHAssetResource has no public size API; the `fileSize` KVC key is widely relied upon.
    /// Guarded so a future SDK without it degrades to 0 instead of raising.
    static func fileSize(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }
    
    private static func nonEmpty(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

/// Off-main library enumeration and item construction.
enum LibraryScanner {
    struct Snapshot: Sendable {
        let items: [SynapsMediaItem]
        /// Assets whose resources haven't been indexed (new, edited since, or indexed by v1). Newest first.
        let needsScan: [String]
    }
    
    static func buildSnapshot(policy: PartPolicy, index: AssetIndex) -> Snapshot {
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let result = PHAsset.fetchAssets(with: fetchOptions)
        
        let records = LocalCacheStore.shared.getAllRecords()
        let partsByAsset = LocalCacheStore.shared.getAllParts()
        
        var items: [SynapsMediaItem] = []
        items.reserveCapacity(result.count)
        var assets: [String: PHAsset] = [:]
        assets.reserveCapacity(result.count)
        var needsScan: [String] = []
        
        // Only cheap PHAsset properties here; PHAssetResource lookups (slow per asset) are done
        // incrementally for assets that are new or changed, and cached in SQLite.
        result.enumerateObjects { asset, _, _ in
            let id = asset.localIdentifier
            assets[id] = asset
            let record = records[id]
            let upToDate = record.map { $0.partsVersion == LocalCacheStore.currentPartsVersion && $0.mtime == asset.synapsMtime } ?? false
            if !upToDate {
                needsScan.append(id)
            }
            items.append(makeItem(asset: asset, record: record, parts: partsByAsset[id] ?? [], policy: policy))
        }
        index.replace(assets, fetchResult: result)
        return Snapshot(items: items, needsScan: needsScan)
    }
    
    /// Indexes resources for the given assets, persists them and returns refreshed items.
    static func scanResources(ids: [String], index: AssetIndex, policy: PartPolicy) -> [SynapsMediaItem] {
        var assets: [PHAsset] = []
        var scans: [LocalCacheStore.ResourceScan] = []
        for id in ids {
            guard let asset = index.asset(for: id) else { continue }
            assets.append(asset)
            scans.append(PartScanner.scan(asset))
        }
        let states = LocalCacheStore.shared.applyResourceScans(scans, policy: policy)
        return assets.map { asset in
            let state = states[asset.localIdentifier]
            return makeItem(asset: asset, record: state?.record, parts: state?.parts ?? [], policy: policy)
        }
    }
    
    /// Rebuilds items from the database (after sync outcomes or policy changes).
    static func items(for ids: [String], index: AssetIndex, policy: PartPolicy) -> [SynapsMediaItem] {
        let states = LocalCacheStore.shared.getStates(assetIds: ids)
        return ids.compactMap { id in
            guard let asset = index.asset(for: id) else { return nil }
            let state = states[id]
            return makeItem(asset: asset, record: state?.record, parts: state?.parts ?? [], policy: policy)
        }
    }
    
    static func makeItem(asset: PHAsset, record: LocalCacheStore.CachedRecord?, parts: [AssetPart], policy: PartPolicy) -> SynapsMediaItem {
        let id = asset.localIdentifier
        let created = asset.creationDate ?? asset.modificationDate ?? Date()
        let modified = asset.modificationDate ?? created
        let primary = parts.first(where: { $0.isPrimary })
        
        let status: SyncStatus
        if !parts.isEmpty {
            status = policy.status(for: parts, lastAttemptFailed: record?.syncStatus == SyncStatus.failed.rawValue)
        } else if let record, let stored = SyncStatus(rawValue: record.syncStatus), stored != .syncing {
            status = stored // indexed by v1 and not re-scanned yet
        } else {
            status = .uncommitted
        }
        
        let filename: String
        if let primary {
            filename = primary.filename
        } else if let recorded = record?.filename, !recorded.isEmpty {
            filename = recorded
        } else {
            filename = "IMG_\(id.prefix(8)).\(asset.mediaType == .video ? "MOV" : "JPG")"
        }
        let fileSize = primary?.size ?? record?.size ?? 0
        let pending = parts.isEmpty ? (status == .committed ? 0 : fileSize) : policy.pendingBytes(parts)
        
        return SynapsMediaItem(
            id: id,
            localIdentifier: id,
            filename: filename,
            fileSize: fileSize,
            createdAt: created,
            modifiedAt: modified,
            isVideo: asset.mediaType == .video,
            isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
            duration: asset.duration,
            isFavorite: asset.isFavorite,
            sha256: primary?.sha256 ?? record?.sha256,
            syncStatus: status,
            width: asset.pixelWidth,
            height: asset.pixelHeight,
            pendingBytes: pending
        )
    }
}

@MainActor
public final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    public static let shared = PhotoLibraryService()
    
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published public private(set) var mediaItems: [SynapsMediaItem] = []
    @Published public private(set) var isLoading: Bool = false
    /// True while file names, sizes and Live Photo / edited parts are being indexed in the background.
    @Published public private(set) var isIndexing: Bool = false
    
    public nonisolated let assetIndex = AssetIndex()
    private nonisolated let imageManager = PHCachingImageManager()
    
    private var indexById: [String: Int] = [:]
    private var syncingIds: Set<String> = []
    private var loadTask: Task<Void, Never>?
    private var reloadRequested = false
    private var scanTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    private var pendingRefreshIds: Set<String> = []
    private var refreshFlushTask: Task<Void, Never>?
    private var observerRegistered = false
    
    private override init() {
        super.init()
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        registerObserverIfAuthorized()
    }
    
    public var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }
    
    private func registerObserverIfAuthorized() {
        guard !observerRegistered, isAuthorized else { return }
        PHPhotoLibrary.shared().register(self)
        observerRegistered = true
    }
    
    public func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        authorizationStatus = status
        if isAuthorized {
            registerObserverIfAuthorized()
            await fetchAllMedia()
            return true
        }
        return false
    }
    
    /// Re-reads the authorization (the user may have changed it in the Settings app) and loads
    /// the library if access was just granted.
    public func refreshAuthorizationStatus() {
        let wasAuthorized = isAuthorized
        authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        registerObserverIfAuthorized()
        if !wasAuthorized && isAuthorized && mediaItems.isEmpty && loadTask == nil {
            Task { await fetchAllMedia() }
        }
    }
    
    /// Reloads the library. Concurrent callers share one in-flight load; a call made while a load
    /// is running schedules exactly one follow-up load and returns after it.
    public func fetchAllMedia() async {
        reloadRequested = true
        if let running = loadTask {
            await running.value
            return
        }
        let task = Task { [weak self] in
            while let self, self.reloadRequested {
                self.reloadRequested = false
                await self.performFetch()
            }
            // Cleared here, in the same main-actor turn as the loop exit, so a request arriving
            // after the last pass can't be lost by awaiting an already-finished task.
            self?.loadTask = nil
        }
        loadTask = task
        await task.value
    }
    
    /// Loads the library once; unlike fetchAllMedia() it doesn't force a reload when items are
    /// already present or a load is in flight (avoids double enumeration at launch).
    public func ensureLoaded() async {
        if let running = loadTask {
            await running.value
            return
        }
        if mediaItems.isEmpty {
            await fetchAllMedia()
        }
    }
    
    private func performFetch() async {
        refreshAuthorizationStatus()
        guard isAuthorized else {
            mediaItems = []
            indexById = [:]
            return
        }
        isLoading = true
        let policy = PartPolicy(config: SynapsConfig.load())
        let index = assetIndex
        let snapshot = await Task.detached(priority: .userInitiated) {
            LibraryScanner.buildSnapshot(policy: policy, index: index)
        }.value
        publish(snapshot.items)
        isLoading = false
        startResourceScan(ids: snapshot.needsScan, policy: policy)
    }
    
    private func publish(_ newItems: [SynapsMediaItem]) {
        var items = newItems
        if !syncingIds.isEmpty {
            for i in items.indices where syncingIds.contains(items[i].id) {
                items[i].syncStatus = .syncing
            }
        }
        indexById = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        mediaItems = items
    }
    
    private func applyItems(_ updated: [SynapsMediaItem]) {
        guard !updated.isEmpty else { return }
        var items = mediaItems
        var changed = false
        for var item in updated {
            guard let idx = indexById[item.id], idx < items.count, items[idx].id == item.id else { continue }
            if syncingIds.contains(item.id) {
                item.syncStatus = .syncing
            }
            if items[idx] != item {
                items[idx] = item
                changed = true
            }
        }
        if changed {
            mediaItems = items
        }
    }
    
    private func startResourceScan(ids: [String], policy: PartPolicy) {
        scanTask?.cancel()
        guard !ids.isEmpty else {
            isIndexing = false
            return
        }
        isIndexing = true
        let index = assetIndex
        scanTask = Task { [weak self] in
            var start = 0
            while start < ids.count {
                if Task.isCancelled { return }
                let chunk = Array(ids[start..<min(start + 400, ids.count)])
                start += chunk.count
                let items = await Task.detached(priority: .utility) {
                    LibraryScanner.scanResources(ids: chunk, index: index, policy: policy)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.applyItems(items)
            }
            self?.isIndexing = false
        }
    }
    
    /// Indexes resources (on demand) and returns the parts of the given assets, for the sync engine.
    public nonisolated func ensureParts(for ids: [String], policy: PartPolicy) async -> [String: [AssetPart]] {
        let index = assetIndex
        let result = await Task.detached(priority: .utility) { () -> ([String: [AssetPart]], [String]) in
            var states = LocalCacheStore.shared.getStates(assetIds: ids)
            var toScan: [PHAsset] = []
            for id in ids {
                guard let asset = index.asset(for: id) else { continue }
                if let state = states[id],
                   state.record.partsVersion == LocalCacheStore.currentPartsVersion,
                   state.record.mtime == asset.synapsMtime,
                   !state.parts.isEmpty {
                    continue
                }
                toScan.append(asset)
            }
            if !toScan.isEmpty {
                let merged = LocalCacheStore.shared.applyResourceScans(toScan.map { PartScanner.scan($0) }, policy: policy)
                states.merge(merged) { _, new in new }
            }
            return (states.mapValues { $0.parts }, toScan.map { $0.localIdentifier })
        }.value
        if !result.1.isEmpty {
            await MainActor.run { self.refreshItems(result.1) }
        }
        return result.0
    }
    
    /// Re-reads the given assets' state from the database (coalesced, ~5 Hz max).
    public func refreshItems<S: Sequence>(_ ids: S) where S.Element == String {
        pendingRefreshIds.formUnion(ids)
        guard refreshFlushTask == nil, !pendingRefreshIds.isEmpty else { return }
        refreshFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard let self else { return }
            let ids = Array(self.pendingRefreshIds)
            self.pendingRefreshIds.removeAll()
            let policy = PartPolicy(config: SynapsConfig.load())
            let index = self.assetIndex
            let items = await Task.detached(priority: .userInitiated) {
                LibraryScanner.items(for: ids, index: index, policy: policy)
            }.value
            self.applyItems(items)
            self.refreshFlushTask = nil
            if !self.pendingRefreshIds.isEmpty {
                self.refreshItems([String]())
            }
        }
    }
    
    /// Re-derives every status after the part policy changed (Settings toggles).
    public func policyDidChange() {
        let policy = PartPolicy(config: SynapsConfig.load())
        Task {
            await Task.detached(priority: .userInitiated) {
                LocalCacheStore.shared.recomputeStatuses(policy: policy)
            }.value
            await fetchAllMedia()
        }
    }
    
    /// Shows/clears the in-flight spinner. Not persisted: a crash never leaves items "syncing".
    public func setSyncing(_ ids: [String], active: Bool) {
        guard !ids.isEmpty else { return }
        if active {
            syncingIds.formUnion(ids)
            var items = mediaItems
            for id in ids {
                if let idx = indexById[id], idx < items.count {
                    items[idx].syncStatus = .syncing
                }
            }
            mediaItems = items
        } else {
            syncingIds.subtract(ids)
            refreshItems(ids)
        }
    }
    
    public func item(withId id: String) -> SynapsMediaItem? {
        guard let idx = indexById[id], idx < mediaItems.count, mediaItems[idx].id == id else { return nil }
        return mediaItems[idx]
    }
    
    // MARK: - PHPhotoLibraryChangeObserver
    
    public nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        // Ignore changes that don't touch our fetch (album edits etc.); otherwise debounce, since
        // iCloud sync can deliver bursts of change notifications.
        if let fetchResult = assetIndex.fetchResult, changeInstance.changeDetails(for: fetchResult) == nil {
            return
        }
        Task { @MainActor in
            self.scheduleReloadAfterChange()
        }
    }
    
    private func scheduleReloadAfterChange() {
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.fetchAllMedia()
            SyncManager.shared.libraryDidChange()
        }
    }
    
    // MARK: - Image requests
    
    private nonisolated static func thumbnailOptions() -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        return options
    }
    
    /// Streams a fast degraded image then the final one. Cancelling the consuming task (e.g. a
    /// cell's `.task` ending when it scrolls away) cancels the PhotoKit request.
    public nonisolated func imageStream(
        for localIdentifier: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode = .aspectFill
    ) -> AsyncStream<UIImage> {
        let manager = imageManager
        let index = assetIndex
        return AsyncStream { continuation in
            guard let asset = index.asset(for: localIdentifier) else {
                continuation.finish()
                return
            }
            let options = contentMode == .aspectFill ? Self.thumbnailOptions() : {
                let o = PHImageRequestOptions()
                o.isNetworkAccessAllowed = true
                o.deliveryMode = .opportunistic
                o.resizeMode = .fast
                return o
            }()
            let requestId = manager.requestImage(for: asset, targetSize: targetSize, contentMode: contentMode, options: options) { image, info in
                if let image {
                    continuation.yield(image)
                }
                let degraded = (info?[PHImageResultIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if !degraded || info?[PHImageCancelledKey] != nil || info?[PHImageErrorKey] != nil {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                manager.cancelImageRequest(requestId)
            }
        }
    }
    
    /// Streamable player item for a video asset (downloads from iCloud when needed).
    public func playerItem(for localIdentifier: String) async -> AVPlayerItem? {
        guard let asset = assetIndex.asset(for: localIdentifier) else { return nil }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        let manager = imageManager
        let box = await withCheckedContinuation { (continuation: CheckedContinuation<PlayerItemBox, Never>) in
            manager.requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                continuation.resume(returning: PlayerItemBox(playerItem))
            }
        }
        return box.item
    }
    
    /// Preheats thumbnails just outside the visible range of the grid.
    public nonisolated func startCaching(ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap { assetIndex.asset(for: $0) }
        guard !assets.isEmpty else { return }
        imageManager.startCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: Self.thumbnailOptions())
    }
    
    public nonisolated func stopCaching(ids: [String], targetSize: CGSize) {
        let assets = ids.compactMap { assetIndex.asset(for: $0) }
        guard !assets.isEmpty else { return }
        imageManager.stopCachingImages(for: assets, targetSize: targetSize, contentMode: .aspectFill, options: Self.thumbnailOptions())
    }
    
    public nonisolated func stopCachingAll() {
        imageManager.stopCachingImagesForAllAssets()
    }
}
