import Foundation
import ImageCaptureCore

public struct ConnectedPhoneInfo: Identifiable {
    public let id: String
    public let name: String
    public let model: String
    public let transportType: String
    public let totalItems: Int
}

public final class iPhoneManager: NSObject, ObservableObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    public static let shared = iPhoneManager()
    
    @Published public var connectedDevice: ConnectedPhoneInfo?
    @Published public var isScanningPhone: Bool = false
    @Published public var phoneMediaItems: [SynapsFileItem] = []
    @Published public var detectedAlbums: [String] = []
    
    private let browser = ICDeviceBrowser()
    private var activeCamera: ICCameraDevice?
    private let stagingDir: URL
    
    public override init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.stagingDir = home.appendingPathComponent(".config/synaps/staging_iphone", isDirectory: true)
        super.init()
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        startMonitoring()
    }
    
    public func startMonitoring() {
        browser.delegate = self
        browser.start()
    }
    
    public func stopMonitoring() {
        browser.stop()
    }
    
    // MARK: - ICDeviceBrowserDelegate
    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        if let camera = device as? ICCameraDevice {
            self.activeCamera = camera
            camera.delegate = self
            camera.requestOpenSession()
            
            DispatchQueue.main.async {
                self.connectedDevice = ConnectedPhoneInfo(
                    id: camera.uuidString ?? UUID().uuidString,
                    name: camera.name ?? "iPhone",
                    model: "iOS Device",
                    transportType: camera.transportType ?? "USB-C",
                    totalItems: camera.mediaFiles?.count ?? 0
                )
            }
        }
    }
    
    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        if device == activeCamera {
            activeCamera = nil
            DispatchQueue.main.async {
                self.connectedDevice = nil
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
    
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable : Any]?, for item: ICCameraItem, error: Error?) {}
    public func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    public func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    public func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {}
    public func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    public func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
    
    private func updateDeviceMediaList(_ camera: ICCameraDevice) {
        guard let files = camera.mediaFiles as? [ICCameraFile] else { return }
        
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
                
                // Check if already synced in local cache
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
}
