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
    private var cameraFilesByName: [String: ICCameraFile] = [:]
    private let thumbnailCache = NSCache<NSString, NSImage>()
    
    public var importDirectoryURL: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
        return pictures.appendingPathComponent("Synaps Imports", isDirectory: true)
    }
    
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
    
    public func checkDeviceStatus() {
        guard let camera = activeCamera else { return }
        DispatchQueue.main.async {
            self.isDeviceLocked = camera.isLocked || camera.isAccessRestrictedAppleDevice
        }
        if !self.isDeviceLocked {
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
            
            DispatchQueue.main.async {
                self.isDeviceLocked = locked
                self.connectedDevice = ConnectedPhoneInfo(
                    id: camera.uuidString ?? UUID().uuidString,
                    name: camera.name ?? "iPhone",
                    model: "iOS Device",
                    transportType: camera.transportType ?? "USB",
                    totalItems: camera.mediaFiles?.count ?? 0
                )
            }
        }
    }
    
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == activeCamera {
            activeCamera = nil
            cameraFilesByName.removeAll()
            DispatchQueue.main.async {
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
            DispatchQueue.main.async {
                self.isDeviceLocked = camera.isLocked || camera.isAccessRestrictedAppleDevice
            }
            updateDeviceMediaList(camera)
        }
    }
    
    public func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    public func didRemove(_ device: ICDevice) {}
    
    // MARK: - ICCameraDeviceDelegate
    public func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {
        updateDeviceMediaList(camera)
    }
    
    public func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {
        updateDeviceMediaList(camera)
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
        guard let cgImage = thumbnail, let name = item.name else { return }
        let nsImage = downscaleCGImage(cgImage, targetDimension: 160)
        let cost = Int(nsImage.size.width * nsImage.size.height * 4)
        thumbnailCache.setObject(nsImage, forKey: name as NSString, cost: cost)
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
    public func getThumbnail(for filename: String) -> NSImage? {
        return thumbnailCache.object(forKey: filename as NSString)
    }
    
    public func loadThumbnail(for filename: String, completion: @escaping (NSImage?) -> Void) {
        if let cached = thumbnailCache.object(forKey: filename as NSString) {
            completion(cached)
            return
        }
        
        guard let file = cameraFilesByName[filename] else {
            completion(nil)
            return
        }
        
        // Fast path: thumbnail already generated and cached on ICCameraFile
        if let cgThumb = file.thumbnail {
            let nsImage = downscaleCGImage(cgThumb, targetDimension: 160)
            let cost = Int(nsImage.size.width * nsImage.size.height * 4)
            thumbnailCache.setObject(nsImage, forKey: filename as NSString, cost: cost)
            completion(nsImage)
            return
        }
        
        // Block-based asynchronous request directly from device
        file.requestThumbnailData(options: nil) { [weak self] data, error in
            guard let self = self else { return }
            if let data = data, let img = self.downscaleData(data, targetDimension: 160) {
                let cost = Int(img.size.width * img.size.height * 4)
                self.thumbnailCache.setObject(img, forKey: filename as NSString, cost: cost)
                DispatchQueue.main.async {
                    completion(img)
                }
            } else {
                // Delegate fallback
                file.requestThumbnail()
            }
        }
    }
    
    public func requestThumbnail(for filename: String) {
        loadThumbnail(for: filename) { _ in }
    }
    
    // MARK: - Media List Update
    private func updateDeviceMediaList(_ camera: ICCameraDevice) {
        let isLocked = camera.isLocked || camera.isAccessRestrictedAppleDevice
        DispatchQueue.main.async {
            self.isDeviceLocked = isLocked
        }
        guard !isLocked else { return }
        guard let files = camera.mediaFiles as? [ICCameraFile] else { return }
        
        var fileDict: [String: ICCameraFile] = [:]
        for file in files {
            if let name = file.name {
                fileDict[name] = file
            }
        }
        self.cameraFilesByName = fileDict
        
        DispatchQueue.global(qos: .userInitiated).async {
            var items: [SynapsFileItem] = []
            var albumsSet = Set<String>()
            let cacheStore = LocalCacheStore.shared
            
            for file in files {
                guard let name = file.name else { continue }
                let fileSize = file.fileSize
                let mtime = file.fileCreationDate ?? Date()
                let virtualPath = "iPhone://\(name)"
                
                var status: SyncStatus = .uncommitted
                var sha: String? = nil
                var isFav = false
                var album: String? = nil
                
                if let cached = cacheStore.getRecord(for: virtualPath) {
                    if cached.size == fileSize {
                        status = cached.syncStatus == SyncStatus.committed.rawValue ? .committed : .uncommitted
                        sha = cached.sha256
                        isFav = cached.isFavorite
                        album = cached.album
                    }
                }
                
                if let album = album {
                    albumsSet.insert(album)
                }
                
                let item = SynapsFileItem(
                    id: virtualPath,
                    originalPath: virtualPath,
                    filename: name,
                    fileSize: fileSize,
                    sourceLocation: "iPhone Camera Roll",
                    modifiedAt: mtime,
                    createdAt: mtime,
                    sha256: sha,
                    syncStatus: status,
                    isDirectory: false,
                    isFavorite: isFav,
                    albumName: album,
                    sourceId: "iphone_harsh",
                    isLivePhotoVideo: name.lowercased().hasSuffix(".mov")
                )
                items.append(item)
            }
            
            items.sort { $0.modifiedAt > $1.modifiedAt }
            
            DispatchQueue.main.async {
                self.phoneMediaItems = items
                self.detectedAlbums = Array(albumsSet).sorted()
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
    
    // MARK: - Download / Import Implementation
    private func downloadFile(_ cameraFile: ICCameraFile, to directoryURL: URL) async -> URL? {
        guard activeCamera != nil else { return nil }
        
        let filename = cameraFile.name ?? "photo.jpg"
        let expectedDest = directoryURL.appendingPathComponent(filename)
        
        let options: [ICDownloadOption: Any] = [
            .downloadsDirectoryURL: directoryURL as NSURL,
            .overwrite: NSNumber(value: true),
            ICDownloadOption(rawValue: "ICOverwriteExistingFile"): NSNumber(value: true)
        ]
        
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
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutWork)
            
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
    
    @MainActor
    public func importItems(filenames: [String]) async {
        guard !filenames.isEmpty else { return }
        guard activeCamera != nil else {
            importStatusMessage = "No iPhone connected"
            return
        }
        
        let filesToDownload = filenames.compactMap { cameraFilesByName[$0] }
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
        
        for (index, file) in filesToDownload.enumerated() {
            let name = file.name ?? "file"
            importStatusMessage = "[\(index + 1)/\(total)] Importing \(name)..."
            
            if let downloadedURL = await downloadFile(file, to: destDir) {
                importedItemsCount += 1
                let virtualPath = "iPhone://\(name)"
                importedVirtualPaths.insert(virtualPath)
                
                // Hash and index into local cache store
                if let sha = HashEngine.computeSHA256(for: downloadedURL.path) {
                    let stat = try? FileManager.default.attributesOfItem(atPath: downloadedURL.path)
                    let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
                    let fileSize = (stat?[.size] as? NSNumber)?.int64Value ?? file.fileSize
                    let now = Date().timeIntervalSince1970
                    
                    // Save local imported file record
                    LocalCacheStore.shared.saveRecord(LocalCacheStore.CachedRecord(
                        path: downloadedURL.path,
                        inode: inode,
                        size: fileSize,
                        mtime: now,
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
                        size: file.fileSize,
                        mtime: now,
                        sha256: sha,
                        lastSyncedAt: now,
                        syncStatus: SyncStatus.committed.rawValue,
                        album: "iPhone Import",
                        isFavorite: false
                    ))
                }
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
        let script = "display notification \"\(message)\" with title \"\(title)\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        try? p.run()
    }
}
