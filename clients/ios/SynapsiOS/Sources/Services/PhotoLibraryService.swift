import Foundation
import Photos
import UIKit
import Combine

public final class PhotoLibraryService: NSObject, ObservableObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    public static let shared = PhotoLibraryService()
    
    @Published public private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published public private(set) var mediaItems: [SynapsMediaItem] = []
    @Published public private(set) var isLoading: Bool = false
    
    public var onLibraryChanged: (() -> Void)?
    
    private let imageManager = PHCachingImageManager()
    private var allPhotosFetchResult: PHFetchResult<PHAsset>?
    private let queue = DispatchQueue(label: "com.synaps.ios.photolibrary", qos: .userInitiated)
    
    public override init() {
        super.init()
        self.authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        PHPhotoLibrary.shared().register(self)
    }
    
    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }
    
    public func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await MainActor.run {
            self.authorizationStatus = status
        }
        if status == .authorized || status == .limited {
            await fetchAllMedia()
            return true
        }
        return false
    }
    
    public func fetchAllMedia() async {
        await MainActor.run {
            self.isLoading = true
        }
        
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        
        let result = PHAsset.fetchAssets(with: fetchOptions)
        self.allPhotosFetchResult = result
        
        let cachedRecords = LocalCacheStore.shared.getAllRecords()
        
        var items: [SynapsMediaItem] = []
        items.reserveCapacity(result.count)
        
        let count = result.count
        for i in 0..<count {
            let asset = result.object(at: i)
            let id = asset.localIdentifier
            
            // Extract filename from resources or fallback
            let resources = PHAssetResource.assetResources(for: asset)
            let primaryResource = resources.first(where: {
                $0.type == .photo || $0.type == .video || $0.type == .pairedVideo || $0.type == .fullSizePhoto
            }) ?? resources.first
            
            let filename = primaryResource?.originalFilename ?? "IMG_\(id.prefix(8)).\(asset.mediaType == .video ? "MOV" : "JPG")"
            
            // Determine size: check resource unsignedLongLong value or cached
            var fileSize: Int64 = 0
            if let primary = primaryResource,
               let sizeVal = primary.value(forKey: "fileSize") as? Int64, sizeVal > 0 {
                fileSize = sizeVal
            }
            
            let isVideo = asset.mediaType == .video
            let isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
            let duration = asset.duration
            let isFav = asset.isFavorite
            let created = asset.creationDate ?? Date()
            let modified = asset.modificationDate ?? created
            
            var status: SyncStatus = .uncommitted
            var sha: String? = nil
            
            if let cached = cachedRecords[id] {
                status = SyncStatus(rawValue: cached.syncStatus) ?? .uncommitted
                sha = cached.sha256
                if fileSize == 0 { fileSize = cached.size }
            } else {
                // Not in database yet -> default is uncommitted (red cross)
                LocalCacheStore.shared.upsertRecord(
                    id: id,
                    filename: filename,
                    size: fileSize,
                    mtime: modified.timeIntervalSince1970,
                    sha256: nil,
                    syncStatus: .uncommitted,
                    isFavorite: isFav
                )
            }
            
            let item = SynapsMediaItem(
                id: id,
                localIdentifier: id,
                filename: filename,
                fileSize: fileSize,
                createdAt: created,
                modifiedAt: modified,
                isVideo: isVideo,
                isLivePhoto: isLivePhoto,
                duration: duration,
                isFavorite: isFav,
                sha256: sha,
                syncStatus: status,
                width: asset.pixelWidth,
                height: asset.pixelHeight
            )
            items.append(item)
        }
        
        let finalItems = items
        await MainActor.run {
            self.mediaItems = finalItems
            self.isLoading = false
        }
    }
    
    // MARK: - PHPhotoLibraryChangeObserver
    public func photoLibraryDidChange(_ changeInstance: PHChange) {
        guard let fetchResult = allPhotosFetchResult,
              let changes = changeInstance.changeDetails(for: fetchResult) else {
            return
        }
        
        Task {
            await self.fetchAllMedia()
            self.onLibraryChanged?()
        }
    }
    
    // MARK: - Image & Asset Requests
    public func requestThumbnail(
        for localIdentifier: String,
        targetSize: CGSize = CGSize(width: 320, height: 320),
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            completion(nil)
            return
        }
        
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        
        imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: options
        ) { image, _ in
            completion(image)
        }
    }
    
    public func requestFullImage(
        for localIdentifier: String,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            completion(nil)
            return
        }
        
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        
        imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            completion(image)
        }
    }
    
    /// Exports the original raw file from PHAsset to a temporary URL so it can be hashed and uploaded.
    public func exportAssetToFile(localIdentifier: String) async throws -> URL {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = assets.firstObject else {
            throw NSError(domain: "PhotoLibraryService", code: 404, userInfo: [NSLocalizedDescriptionKey: "Asset not found: \(localIdentifier)"])
        }
        
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primaryResource = resources.first(where: {
            $0.type == .photo || $0.type == .video || $0.type == .pairedVideo || $0.type == .fullSizePhoto
        }) ?? resources.first else {
            throw NSError(domain: "PhotoLibraryService", code: 404, userInfo: [NSLocalizedDescriptionKey: "No primary resource found for asset"])
        }
        
        let ext = (primaryResource.originalFilename as NSString).pathExtension
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("synaps_export_\(UUID().uuidString).\(ext.isEmpty ? "tmp" : ext)")
        
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: primaryResource, toFile: tempFile, options: options) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        
        return tempFile
    }
}
