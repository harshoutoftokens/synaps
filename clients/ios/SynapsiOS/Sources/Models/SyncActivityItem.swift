import Foundation

public struct SyncActivityItem: Identifiable, Codable, Sendable {
    public let id: String
    public let timestamp: Date
    public let eventType: EventType
    public let filePath: String
    public let filename: String
    public let details: String
    public let sourceId: String
    
    public enum EventType: String, Codable, Sendable {
        case committed = "COMMITTED"
        case dedupLinked = "DEDUP_LINKED"
        case uploaded = "UPLOADED"
        case failed = "FAILED"
        case scanned = "SCANNED"
        
        public var iconName: String {
            switch self {
            case .committed: return "checkmark.seal.fill"
            case .dedupLinked: return "link.circle.fill"
            case .uploaded: return "arrow.up.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            case .scanned: return "magnifyingglass"
            }
        }
    }
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        eventType: EventType,
        filePath: String,
        filename: String,
        details: String,
        sourceId: String = "iphone_harsh"
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.filePath = filePath
        self.filename = filename
        self.details = details
        self.sourceId = sourceId
    }
}
