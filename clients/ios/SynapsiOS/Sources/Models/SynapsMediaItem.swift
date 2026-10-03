import Foundation
import Photos

public struct SynapsMediaItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let localIdentifier: String
    public var filename: String
    public var fileSize: Int64
    public var createdAt: Date
    public var modifiedAt: Date
    public var isVideo: Bool
    public var isLivePhoto: Bool
    public var duration: TimeInterval
    public var isFavorite: Bool
    public var sha256: String?
    public var syncStatus: SyncStatus
    public var width: Int
    public var height: Int
    
    public init(
        id: String,
        localIdentifier: String,
        filename: String,
        fileSize: Int64,
        createdAt: Date,
        modifiedAt: Date,
        isVideo: Bool = false,
        isLivePhoto: Bool = false,
        duration: TimeInterval = 0,
        isFavorite: Bool = false,
        sha256: String? = nil,
        syncStatus: SyncStatus = .uncommitted,
        width: Int = 0,
        height: Int = 0
    ) {
        self.id = id
        self.localIdentifier = localIdentifier
        self.filename = filename
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.isVideo = isVideo
        self.isLivePhoto = isLivePhoto
        self.duration = duration
        self.isFavorite = isFavorite
        self.sha256 = sha256
        self.syncStatus = syncStatus
        self.width = width
        self.height = height
    }
    
    public var originalPath: String {
        return "ph://\(localIdentifier)/\(filename)"
    }
    
    public var formattedDuration: String? {
        guard isVideo && duration > 0 else { return nil }
        let totalSeconds = Int(duration)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes >= 60 {
            let hours = minutes / 60
            let remMinutes = minutes % 60
            return String(format: "%d:%02d:%02d", hours, remMinutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    public var formattedSize: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: fileSize)
    }
    
    public var formattedDimensions: String {
        guard width > 0 && height > 0 else { return "" }
        return "\(width) × \(height)"
    }
}
