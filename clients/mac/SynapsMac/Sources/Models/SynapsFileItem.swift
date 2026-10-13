import Foundation

public struct SynapsFileItem: Identifiable, Hashable {
    public let id: String
    public var originalPath: String
    public var filename: String
    public var fileSize: Int64
    public var sourceLocation: String
    public var modifiedAt: Date
    public var createdAt: Date
    public var sha256: String?
    public var syncStatus: SyncStatus
    public var isDirectory: Bool
    public var isFavorite: Bool
    public var albumName: String?
    public var sourceId: String
    public var isLivePhotoVideo: Bool
    
    public init(
        id: String,
        originalPath: String,
        filename: String,
        fileSize: Int64,
        sourceLocation: String,
        modifiedAt: Date,
        createdAt: Date = Date(),
        sha256: String? = nil,
        syncStatus: SyncStatus = .uncommitted,
        isDirectory: Bool = false,
        isFavorite: Bool = false,
        albumName: String? = nil,
        sourceId: String = "mac_harsh",
        isLivePhotoVideo: Bool = false
    ) {
        self.id = id
        self.originalPath = originalPath
        self.filename = filename
        self.fileSize = fileSize
        self.sourceLocation = sourceLocation
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
        self.sha256 = sha256
        self.syncStatus = syncStatus
        self.isDirectory = isDirectory
        self.isFavorite = isFavorite
        self.albumName = albumName
        self.sourceId = sourceId
        self.isLivePhotoVideo = isLivePhotoVideo
    }
    
    public var isImageOrVideo: Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mediaExtensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "raw", "dng", "mov", "mp4", "m4v", "avi", "mkv"]
        return mediaExtensions.contains(ext)
    }
    
    public var formattedSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: fileSize)
    }
}
