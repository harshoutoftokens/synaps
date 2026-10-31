import SwiftUI

public enum SyncStatus: String, Codable, CaseIterable {
    case committed      // 🟢 Synced and verified in NAS vault
    case uncommitted    // 🔴 New or modified file, not yet on NAS
    case syncing        // ⏳ Currently transferring
    case failed         // ⚠️ Upload failed
    
    public var iconSystemName: String {
        switch self {
        case .committed:
            return "checkmark.circle.fill"
        case .uncommitted:
            return "xmark.circle.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.circle.fill"
        }
    }
    
    public var color: Color {
        switch self {
        case .committed:
            return Color.green
        case .uncommitted:
            return Color.red
        case .syncing:
            return Color.blue
        case .failed:
            return Color.orange
        }
    }
    
    public var labelText: String {
        switch self {
        case .committed:
            return "Committed"
        case .uncommitted:
            return "Uncommitted"
        case .syncing:
            return "Syncing..."
        case .failed:
            return "Failed"
        }
    }
}
