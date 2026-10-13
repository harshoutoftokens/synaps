import Foundation
import ImageCaptureCore
import AppKit
import ImageIO

public struct ConnectedPhoneInfo: Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let transportType: String
    public let totalItems: Int
}

/// Plain values copied out of an ICCameraFile so the list can be built off the main thread.
private struct PhoneFileEntry: Sendable {
    let id: String
    let name: String
    let size: Int64
    let date: Date
}

public final class iPhoneManager: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate, ICCameraDeviceDownloadDelegate {
    public static let shared = iPhoneManager()
    
    @Published public var connectedDevice: ConnectedPhoneInfo?
    @Published public var isScanningPhone: Bool = false
    @Published public var isDeviceLocked: Bool = false
    @Published public var phoneMediaItems: [SynapsFileItem] = []
    @Published public var detectedAlbums: [String] = []
    
    @Published public var thumbnailsVersion: Int = 0
    @Published public var isImporting: Bool = false
    @Published public var importProgress: Double = 0.0
    @Published public var importStatusMessage: String = ""
    @Published public var importedItemsCount: Int = 0
    
    private let browser = ICDeviceBrowser()
    private var activeCamera: ICCameraDevice?
    /// Keyed by item id ("iPhone://<DCIM folder>/<name>"): file names alone repeat on a phone
    /// (100APPLE/IMG_0001.JPG and 105APPLE/IMG_0001.JPG), which used to hide one of the photos.
    private var cameraFilesById: [String: ICCameraFile] = [:]
    private let thumbnailCache = NSCache<NSString, NSImage>()
    /// Coalesces the burst of didAdd callbacks while the phone's catalog loads.
    private var pendingListUpdate: DispatchWorkItem?
    private var listGeneration = 0
    /// Phone items already looked up on the NAS this session (main thread only).
    private var nasMatchCheckedIds = Set<String>()
    
    public let importDirectoryURL: URL = {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("Synaps Imports", isDirectory: true)
    }()
    
    public override init() {
        super.init()
        thumbnailCache.countLimit = 250
        thumbnailCache.totalCostLimit = 40 * 1024 * 1024 // 40 MB max cache to keep RAM pressure minimal
        try? FileManager.default.createDirectory(at: importDirectoryURL, withIntermediateDirectories: true)
        startMonitoring()
    }
    
    public func startMonitoring() {
        browser.delegate = self
        browser.start()
    }
    
    public func stopMonitoring() {
        browser.stop()
    }
    
    /// Stable id of a camera item, also used as its SynapsFileItem id and cache key.
    private static func identifier(for item: ICCameraItem) -> String {
        let name = item.name ?? ""
        if let folder = item.parentFolder?.name, !folder.isEmpty {
            return "iPhone://\(folder)/\(name)"
        }
        return "iPhone://\(name)"
    }
    
    /// Record keys written by earlier versions (by name only; stored relative to the working directory).
    private static func legacyKeys(forName name: String) -> [String] {
        return ["iPhone://\(name)", "/iPhone:/\(name)"]
    }
    
    public func checkDeviceStatus() {
        guard let camera = activeCamera else { return }
        // Decide on the fresh value; the published flag is only updated asynchronously.
        let locked = camera.isLocked || camera.isAccessRestrictedAppleDevice
        DispatchQueue.main.async {
            self.isDeviceLocked = locked
        }
        if !locked {
            updateDeviceMediaList(camera)
        }
    }
    
    // MARK: - ICDeviceBrowserDelegate
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if let camera = device as? ICCameraDevice {
            self.activeCamera = camera
            camera.delegate = self
            camera.requestOpenSession()
            
            let locked = camera.isLocked || camera.isAccessRestrictedAppleDevice
            let info = ConnectedPhoneInfo(
                id: camera.uuidString ?? UUID().uuidString,
                name: camera.name ?? "iPhone",
                model: "iOS Device",
                transportType: camera.transportType ?? "USB",
                totalItems: camera.mediaFiles?.count ?? 0
            )
            
            DispatchQueue.main.async {
                self.isDeviceLocked = locked
                self.connectedDevice = info
            }
        }
    }
    
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == activeCamera {
            activeCamera = nil
            cameraFilesById.removeAll()
            pendingListUpdate?.cancel()
            // Another phone may use the same folder/file names
            thumbnailCache.removeAllObjects()
            DispatchQueue.main.async {
                self.listGeneration += 1
                self.connectedDevice = nil
                self.isDeviceLocked = false
                self.phoneMediaItems = []
                self.detectedAlbums = []
            }
        }
    }
    
    // MARK: - ICDeviceDelegate
    public func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error = error {
            print("Error opening session to device: \(error.localizedDescription)")
            return
        }
        if let camera = device as? ICCameraDevice {
            let locked = camera.isLocked || camera.isAccessRestrictedAppleDevice
            DispatchQueue.main.async {
                self.isDeviceLocked = locked
            }
            updateDeviceMediaList(camera)
        }
    }
    
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    public func didRemove(_ device: ICDevice) {}
    
    // MARK: - ICCameraDeviceDelegate
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        scheduleMediaListUpdate(camera)
    }
    
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        scheduleMediaListUpdate(camera)
    }
    
    public func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        updateDeviceMediaList(device)
    }
    
    // MARK: - Safe Downscaling & Memory Management
    private func downscaleData(_ data: Data, targetDimension: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        let maxPixelSize = Int(targetDimension)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        if let thumbCG = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return NSImage(cgImage: thumbCG, size: NSSize(width: CGFloat(thumbCG.width), height: CGFloat(thumbCG.height)))
        }
        return nil
    }
    
    private func downscaleCGImage(_ cgImage: CGImage, targetDimension: CGFloat) -> NSImage {
        let width = CGFloat(cgImage.width)
        let height = CGFloat(cgImage.height)
        guard width > targetDimension || height > targetDimension else {
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
        
        let aspect = width / height
        let newWidth: CGFloat
        let newHeight: CGFloat
        if aspect > 1 {
            newWidth = targetDimension
            newHeight = targetDimension / aspect
        } else {
            newWidth = targetDimension * aspect
            newHeight = targetDimension
        }
        
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: Int(newWidth),
            height: Int(newHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return NSImage(cgImage: cgImage, size: NSSize(width: newWidth, height: newHeight))
        }
        
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))
        
        if let scaledCGImage = context.makeImage() {
            return NSImage(cgImage: scaledCGImage, size: NSSize(width: newWidth, height: newHeight))
        }
        
        return NSImage(cgImage: cgImage, size: NSSize(width: newWidth, height: newHeight))
    }
    
    @objc(cameraDevice:didReceiveThumbnail:forItem:error:)
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {
        guard let cgImage = thumbnail, item.name != nil else { return }
        let nsImage = downscaleCGImage(cgImage, targetDimension: 160)
        let cost = Int(nsImage.size.width * nsImage.size.height * 4)
        thumbnailCache.setObject(nsImage, forKey: Self.identifier(for: item) as NSString, cost: cost)
        DispatchQueue.main.async {
            self.thumbnailsVersion += 1
        }
    }
    
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.isDeviceLocked = false
        }
        if let camera = self.activeCamera {
            updateDeviceMediaList(camera)
        }
    }
    
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {
        DispatchQueue.main.async {
            self.isDeviceLocked = true
        }
    }
    
    // MARK: - Thumbnail Retrieval
    public func getThumbnail(for id: String) -> NSImage? {
        return thumbnailCache.object(forKey: id as NSString)
    }
    
    public func loadThumbnail(for id: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: id as NSString) {
            completion(cached)
            return
        }
        
        guard let file = cameraFilesById[id] else {
            completion(nil)
            return
        }
        
        // Fast path: thumbnail already generated and cached on ICCameraFile
        if let cgThumb = file.thumbnail {
            let nsImage = downscaleCGImage(cgThumb, targetDimension: 160)
            let cost = Int(nsImage.size.width * nsImage.size.height * 4)
            thumbnailCache.setObject(nsImage, forKey: id as NSString, cost: cost)
            completion(nsImage)
            return
        }
        
        // Block-based asynchronous request directly from device
        file.requestThumbnailData(options: nil) { [weak self] data, error in
            guard let self = self else { return }
            if let data = data, let img = self.downscaleData(data, targetDimension: 160) {
                let cost = Int(img.size.width * img.size.height * 4)
                self.thumbnailCache.setObject(img, forKey: id as NSString, cost: cost)
                DispatchQueue.main.async {
                    completion(img)
                }
            } else {
                // Delegate fallback
                file.requestThumbnail()
            }
        }
    }
    
    public func requestThumbnail(for id: String) {
        loadThumbnail(for: id) { _ in }
    }
    
    // MARK: - Media List Update
    private func scheduleMediaListUpdate(_ camera: ICCameraDevice) {
        pendingListUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateDeviceMediaList(camera)
        }
        pendingListUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    
    private func updateDeviceMediaList(_ camera: ICCameraDevice) {
        pendingListUpdate?.cancel()
        pendingListUpdate = nil
        let isLocked = camera.isLocked || camera.isAccessRestrictedAppleDevice
        DispatchQueue.main.async {
            self.isDeviceLocked = isLocked
        }
        guard !isLocked else { return }
        // compactMap: a single non-file item used to make the whole cast fail (empty list)
        let files = (camera.mediaFiles ?? []).compactMap { $0 as? ICCameraFile }
        
        // Copy the values we need here; the cache lookups below run on a background queue.
        var fileDict: [String: ICCameraFile] = [:]
        var entries: [PhoneFileEntry] = []
        entries.reserveCapacity(files.count)
        for file in files {
            guard let name = file.name else { continue }
            let id = Self.identifier(for: file)
            fileDict[id] = file
            entries.append(PhoneFileEntry(id: id, name: name, size: file.fileSize, date: file.fileCreationDate ?? Date()))
        }
        self.cameraFilesById = fileDict
        
        listGeneration += 1
        let generation = listGeneration
        
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [SynapsFileItem] = []
            var albumsSet = Set<String>()
            let cacheStore = LocalCacheStore.shared
            
            for entry in entries {
                var status: SyncStatus = .uncommitted
                var sha: String? = nil
                var isFav = false
                var album: String? = nil
                
                let cached = cacheStore.getRecord(for: entry.id)
                    ?? Self.legacyKeys(forName: entry.name).lazy.compactMap { cacheStore.getRecord(for: $0) }.first
                if let cached = cached, cached.size == entry.size {
                    status = cached.syncStatus == SyncStatus.committed.rawValue ? .committed : .uncommitted
                    sha = cached.sha256
                    isFav = cached.isFavorite
                    album = cached.album
                }
                
                if let album = album {
                    albumsSet.insert(album)
                }
                
                let item = SynapsFileItem(
                    id: entry.id,
                    originalPath: entry.id,
                    filename: entry.name,
                    fileSize: entry.size,
                    sourceLocation: "iPhone Camera Roll",
                    modifiedAt: entry.date,
                    createdAt: entry.date,
                    sha256: sha,
                    syncStatus: status,
                    isDirectory: false,
                    isFavorite: isFav,
                    albumName: album,
                    sourceId: "iphone_harsh",
                    isLivePhotoVideo: entry.name.lowercased().hasSuffix(".mov")
                )
                items.append(item)
            }
            
            items.sort { $0.modifiedAt > $1.modifiedAt }
            let albums = Array(albumsSet).sorted()
            
            DispatchQueue.main.async {
                // A newer listing (or a disconnect) superseded this one
                guard generation == self.listGeneration else { return }
                self.phoneMediaItems = items
                self.detectedAlbums = albums
                self.markItemsAlreadyOnNAS(items)
                if let dev = self.connectedDevice {
                    self.connectedDevice = ConnectedPhoneInfo(
                        id: dev.id,
                        name: dev.name,
                        model: dev.model,
                        transportType: dev.transportType,
                        totalItems: items.count
                    )
                }
            }
        }
    }
    
    // MARK: - Items already on the NAS
    
    /// Photos can reach the NAS without this view knowing (AirDropped to the Mac and synced from a
    /// folder, uploaded by the iPhone app, ...). Ask the NAS which phone files it already has, by
    /// file name and size, and remember those as committed. Runs on the main thread.
    private func markItemsAlreadyOnNAS(_ items: [SynapsFileItem]) {
        let unknown = items.filter { $0.syncStatus != .committed && $0.fileSize > 0 && !nasMatchCheckedIds.contains($0.id) }
        guard !unknown.isEmpty else { return }
        nasMatchCheckedIds.formUnion(unknown.map(\.id))
        let lookups = unknown.map { (id: $0.id, file: IngestMatchFile(filename: $0.filename, size: $0.fileSize)) }
        
        Task.detached(priority: .utility) {
            let matches: [IngestMatch]
            do {
                matches = try await NASClient.shared.matchExisting(Array(Set(lookups.map(\.file))))
            } catch {
                // NAS offline or an older server: look these items up again on the next refresh
                print("⚠️ Could not match phone items with the NAS: \(error.localizedDescription)")
                await MainActor.run { iPhoneManager.shared.nasMatchCheckedIds.subtract(lookups.map(\.id)) }
                return
            }
            var shaByFile: [IngestMatchFile: String] = [:]
            for match in matches {
                shaByFile[IngestMatchFile(filename: match.filename, size: match.size)] = match.sha256
            }
            let now = Date().timeIntervalSince1970
            var found: [String: String] = [:]
            for lookup in lookups {
                guard let sha = shaByFile[lookup.file] else { continue }
                found[lookup.id] = sha
                LocalCacheStore.shared.saveRecord(LocalCacheStore.CachedRecord(
                    path: lookup.id,
                    inode: 0,
                    size: lookup.file.size,
                    mtime: now,
                    sha256: sha,
                    lastSyncedAt: now,
                    syncStatus: SyncStatus.committed.rawValue,
                    album: nil,
                    isFavorite: false
                ))
            }
            guard !found.isEmpty else { return }
            let matched = found
            await MainActor.run {
                let manager = iPhoneManager.shared
                for i in manager.phoneMediaItems.indices {
                    if let sha = matched[manager.phoneMediaItems[i].id] {
                        manager.phoneMediaItems[i].syncStatus = .committed
                        manager.phoneMediaItems[i].sha256 = sha
                    }
                }
            }
        }
    }
    
    // MARK: - Download / Import Implementation
    
    /// Downloads into a private staging folder, then moves the file into the import folder under a
    /// unique name. The old in-place overwrite could replace a *different* photo with the same name;
    /// a byte-identical earlier import is reused instead of duplicated.
    private func downloadFile(_ cameraFile: ICCameraFile, to directoryURL: URL) async -> URL? {
        guard activeCamera != nil else { return nil }
        
        let filename = cameraFile.name ?? "photo.jpg"
        let stagingDir = directoryURL.appendingPathComponent(".synaps-staging-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Cannot create staging folder for \(filename): \(error.localizedDescription)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        
        guard let staged = await requestDownload(cameraFile, filename: filename, into: stagingDir) else {
            return nil
        }
        
        // Moving (and possibly hashing to detect an identical earlier import) is blocking I/O
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.placeImportedFile(staged, preferredName: filename, in: directoryURL))
            }
        }
    }
    
    private func requestDownload(_ cameraFile: ICCameraFile, filename: String, into directoryURL: URL) async -> URL? {
        let expectedDest = directoryURL.appendingPathComponent(filename)
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directoryURL as NSURL,
            .overwrite: NSNumber(value: true),
            ICDownloadOption(rawValue: "ICOverwriteExistingFile"): NSNumber(value: true)
        ]
        // A fixed 30 s used to abort multi-GB videos mid-transfer; allow for ~5 MB/s over USB.
        let timeout = max(60.0, 30.0 + Double(max(0, cameraFile.fileSize)) / (5.0 * 1024 * 1024))
        
        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()
            
            // Timeout safety to ensure continuation never hangs if ImageCaptureCore stalls
            let timeoutWork = DispatchWorkItem {
                lock.lock()
                defer { lock.unlock() }
                if !hasResumed {
                    hasResumed = true
                    print("⚠️ Download timed out for \(filename)")
                    continuation.resume(returning: nil)
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
            
            _ = cameraFile.requestDownload(options: options) { savedFilename, error in
                timeoutWork.cancel()
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                
                if let error = error {
                    print("❌ Error downloading \(filename): \(error.localizedDescription)")
                    continuation.resume(returning: nil)
                    return
                }
                
                if let saved = savedFilename, !saved.isEmpty {
                    let dest: URL
                    if saved.hasPrefix("/") {
                        dest = URL(fileURLWithPath: saved)
                    } else {
                        dest = directoryURL.appendingPathComponent(saved)
                    }
                    if FileManager.default.fileExists(atPath: dest.path) {
                        continuation.resume(returning: dest)
                        return
                    }
                }
                
                // Fallback: check if expected destination exists
                if FileManager.default.fileExists(atPath: expectedDest.path) {
                    continuation.resume(returning: expectedDest)
                    return
                }
                
                continuation.resume(returning: nil)
            }
        }
    }
    
    private static func placeImportedFile(_ staged: URL, preferredName: String, in directory: URL) -> URL? {
        let fm = FileManager.default
        let preferred = directory.appendingPathComponent(preferredName)
        if fm.fileExists(atPath: preferred.path), filesHaveSameContent(staged, preferred) {
            return preferred
        }
        do {
            return try fm.moveItemToUniqueURL(at: staged, preferred: preferred)
        } catch {
            print("❌ Could not move imported \(preferredName) into place: \(error.localizedDescription)")
            return nil
        }
    }
    
    private static func filesHaveSameContent(_ a: URL, _ b: URL) -> Bool {
        let fm = FileManager.default
        guard let sizeA = (try? fm.attributesOfItem(atPath: a.path))?[.size] as? NSNumber,
              let sizeB = (try? fm.attributesOfItem(atPath: b.path))?[.size] as? NSNumber,
              sizeA == sizeB else { return false }
        guard let shaA = HashEngine.computeSHA256(for: a.path) else { return false }
        return shaA == HashEngine.computeSHA256(for: b.path)
    }
    
    /// Hashes the imported file and records both the local copy and the phone item as imported.
    /// Runs off the main thread: hashing a 4K video took the UI down with it.
    private static func indexImportedFile(at path: String, virtualPath: String, cameraFileSize: Int64) async {
        guard let sha = await HashEngine.computeSHA256Async(for: path) else { return }
        let stat = try? FileManager.default.attributesOfItem(atPath: path)
        let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        let fileSize = (stat?[.size] as? NSNumber)?.int64Value ?? cameraFileSize
        let now = Date().timeIntervalSince1970
        // The real mtime, so the folder scanner can reuse this hash instead of recomputing it
        let mtime = (stat?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? now
        
        // Save local imported file record
        LocalCacheStore.shared.saveRecord(LocalCacheStore.CachedRecord(
            path: path,
            inode: inode,
            size: fileSize,
            mtime: mtime,
            sha256: sha,
            lastSyncedAt: nil,
            syncStatus: SyncStatus.uncommitted.rawValue,
            album: "iPhone Import",
            isFavorite: false
        ))
        
        // Also mark virtual record as committed
        LocalCacheStore.shared.saveRecord(LocalCacheStore.CachedRecord(
            path: virtualPath,
            inode: 0,
            size: cameraFileSize,
            mtime: now,
            sha256: sha,
            lastSyncedAt: now,
            syncStatus: SyncStatus.committed.rawValue,
            album: "iPhone Import",
            isFavorite: false
        ))
    }
    
    @MainActor
    public func importItems(ids: [String]) async {
        guard !ids.isEmpty, !isImporting else { return }
        guard activeCamera != nil else {
            importStatusMessage = "No iPhone connected"
            return
        }
        
        let filesToDownload = ids.compactMap { id in cameraFilesById[id].map { (id, $0) } }
        guard !filesToDownload.isEmpty else {
            importStatusMessage = "No items matched for import"
            return
        }
        
        isImporting = true
        importProgress = 0.0
        importedItemsCount = 0
        let total = filesToDownload.count
        let destDir = importDirectoryURL
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        
        var importedVirtualPaths = Set<String>()
        
        for (index, (id, file)) in filesToDownload.enumerated() {
            let name = file.name ?? "file"
            importStatusMessage = "[\(index + 1)/\(total)] Importing \(name)..."
            
            if let downloadedURL = await downloadFile(file, to: destDir) {
                importedItemsCount += 1
                importedVirtualPaths.insert(id)
                
                // Hash and index into local cache store
                await Self.indexImportedFile(at: downloadedURL.path, virtualPath: id, cameraFileSize: file.fileSize)
            }
            
            importProgress = Double(index + 1) / Double(total)
        }
        
        // Update phoneMediaItems state in-place
        for i in 0..<self.phoneMediaItems.count {
            if importedVirtualPaths.contains(self.phoneMediaItems[i].originalPath) {
                self.phoneMediaItems[i].syncStatus = .committed
            }
        }
        
        isImporting = false
        importProgress = 1.0
        importStatusMessage = "Imported \(importedItemsCount) of \(total) items to \(destDir.lastPathComponent)"
        
        notify(title: "Synaps Photos Import", message: "Successfully imported \(importedItemsCount) items.")
    }
    
    private func notify(title: String, message: String) {
        UserNotifier.shared.post(title: title, message: message)
    }
}
