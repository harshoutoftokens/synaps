import Foundation
import Photos

/// The kinds of PhotoKit resources Synaps backs up. One photo-library asset maps to one or more
/// files on the NAS: the original, plus e.g. the Live Photo motion video, a RAW companion,
/// or the edited render.
public enum AssetPartKind: String, Sendable, CaseIterable {
    case photo
    case video
    case audio
    case alternatePhoto
    case pairedVideo
    case fullSizePhoto
    case fullSizeVideo
    case fullSizePairedVideo
    
    public init?(resourceType: PHAssetResourceType) {
        switch resourceType {
        case .photo: self = .photo
        case .video: self = .video
        case .audio: self = .audio
        case .alternatePhoto: self = .alternatePhoto
        case .pairedVideo: self = .pairedVideo
        case .fullSizePhoto: self = .fullSizePhoto
        case .fullSizeVideo: self = .fullSizeVideo
        case .fullSizePairedVideo: self = .fullSizePairedVideo
        default: return nil // adjustment data, adjustment bases, proxies, unknown future types
        }
    }
    
    public var resourceType: PHAssetResourceType {
        switch self {
        case .photo: return .photo
        case .video: return .video
        case .audio: return .audio
        case .alternatePhoto: return .alternatePhoto
        case .pairedVideo: return .pairedVideo
        case .fullSizePhoto: return .fullSizePhoto
        case .fullSizeVideo: return .fullSizeVideo
        case .fullSizePairedVideo: return .fullSizePairedVideo
        }
    }
    
    /// Rendered output of an edit made in Photos (the original stays untouched).
    public var isEdit: Bool {
        self == .fullSizePhoto || self == .fullSizeVideo || self == .fullSizePairedVideo
    }
    
    /// Motion half of a Live Photo (original or edited).
    public var isLivePhotoVideo: Bool {
        self == .pairedVideo || self == .fullSizePairedVideo
    }
}

/// One uploadable file of a photo-library asset, plus its cached hash and NAS commit state.
public struct AssetPart: Sendable, Hashable {
    public let assetId: String
    public let kind: AssetPartKind
    /// File name sent to the NAS; unique within the asset.
    public var filename: String
    public var size: Int64
    /// The asset's primary resource (always backed up, regardless of policy).
    public var isPrimary: Bool
    public var sha256: String?
    /// Asset modificationDate (seconds since 1970) at the time `sha256` was computed.
    public var hashMtime: Double?
    /// When the NAS confirmed it holds this exact content (upload or dedup link).
    public var committedAt: Double?
    
    public init(
        assetId: String,
        kind: AssetPartKind,
        filename: String,
        size: Int64,
        isPrimary: Bool,
        sha256: String? = nil,
        hashMtime: Double? = nil,
        committedAt: Double? = nil
    ) {
        self.assetId = assetId
        self.kind = kind
        self.filename = filename
        self.size = size
        self.isPrimary = isPrimary
        self.sha256 = sha256
        self.hashMtime = hashMtime
        self.committedAt = committedAt
    }
    
    /// Provenance path registered on the NAS. The primary part keeps the format used since v1
    /// ("ph://<localIdentifier>/<filename>") so already-synced items keep their identity.
    public var originalPath: String {
        "ph://\(assetId)/\(filename)"
    }
    
    public var isCommitted: Bool {
        committedAt != nil && sha256 != nil
    }
    
    /// Whether the cached hash still describes the resource. Originals are immutable in Photos,
    /// so a size match is enough; edited renders can change on re-edit, so they are also keyed
    /// on the asset's modificationDate.
    public func hashIsValid(size currentSize: Int64, mtime currentMtime: Double) -> Bool {
        guard sha256 != nil, size == currentSize else { return false }
        return !kind.isEdit || hashMtime == currentMtime
    }
}

/// Which parts of an asset must be on the NAS for it to count as committed.
public struct PartPolicy: Sendable, Equatable {
    public var includeEdits: Bool
    public var includeLivePhotoVideos: Bool
    
    public init(includeEdits: Bool, includeLivePhotoVideos: Bool) {
        self.includeEdits = includeEdits
        self.includeLivePhotoVideos = includeLivePhotoVideos
    }
    
    public init(config: SynapsConfig) {
        self.init(includeEdits: config.uploadEditedVersions, includeLivePhotoVideos: config.uploadLivePhotoVideos)
    }
    
    public func includes(_ part: AssetPart) -> Bool {
        if part.isPrimary { return true }
        if part.kind.isLivePhotoVideo && !includeLivePhotoVideos { return false }
        if part.kind.isEdit && !includeEdits { return false }
        return true
    }
    
    public func expectedParts(_ parts: [AssetPart]) -> [AssetPart] {
        parts.filter { includes($0) }
    }
    
    /// Committed when every expected part is on the NAS. `failed` is sticky until the next attempt.
    public func status(for parts: [AssetPart], lastAttemptFailed: Bool) -> SyncStatus {
        let expected = expectedParts(parts)
        if !expected.isEmpty && expected.allSatisfy({ $0.isCommitted }) {
            return .committed
        }
        return lastAttemptFailed ? .failed : .uncommitted
    }
    
    public func pendingBytes(_ parts: [AssetPart]) -> Int64 {
        expectedParts(parts).filter { !$0.isCommitted }.reduce(0) { $0 + $1.size }
    }
}
