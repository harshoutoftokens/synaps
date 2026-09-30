import Foundation
import SwiftUI

public struct SyncActivityItem: Identifiable, Codable {
    public let id: String
    public let timestamp: Date
    public let eventType: SyncActivityType
    public let filePath: String?
    public let filename: String?
    public let details: String
    public let sourceId: String?
    
    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        eventType: SyncActivityType,
        filePath: String? = nil,
        filename: String? = nil,
        details: String,
        sourceId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.eventType = eventType
        self.filePath = filePath
        self.filename = filename
        self.details = details
        self.sourceId = sourceId
    }
    
    public enum SyncActivityType: String, Codable {
        case existingDiscovered = "existing_discovered"
        case fileSynced = "file_synced"
        case folderSynced = "folder_synced"
        case syncStarted = "sync_started"
        case syncCompleted = "sync_completed"
        case syncFailed = "sync_failed"
        case statusReconciled = "status_reconciled"
        
        public var title: String {
            switch self {
            case .existingDiscovered: return "Existing File Detected on NAS"
            case .fileSynced: return "File Synced to NAS"
            case .folderSynced: return "Folder Synced to NAS"
            case .syncStarted: return "Sync Started"
            case .syncCompleted: return "Sync Completed"
            case .syncFailed: return "Sync Failed"
            case .statusReconciled: return "NAS State Reconciled"
            }
        }
        
        public var iconName: String {
            switch self {
            case .existingDiscovered: return "link.circle.fill"
            case .fileSynced: return "arrow.up.circle.fill"
            case .folderSynced: return "folder.badge.gearshape"
            case .syncStarted: return "arrow.triangle.2.circlepath"
            case .syncCompleted: return "checkmark.circle.fill"
            case .syncFailed: return "exclamationmark.triangle.fill"
            case .statusReconciled: return "arrow.2.squarepath"
            }
        }
        
        public var color: Color {
            switch self {
            case .existingDiscovered: return .blue
            case .fileSynced, .folderSynced, .syncCompleted: return .green
            case .syncStarted, .statusReconciled: return .accentColor
            case .syncFailed: return .red
            }
        }
    }
}
