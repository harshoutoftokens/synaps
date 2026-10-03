import SwiftUI
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var config: SynapsConfig
    @Published public var isTestingConnection: Bool = false
    @Published public var connectionStatusMessage: String = ""
    @Published public var connectionSuccess: Bool? = nil
    @Published public var recentActivities: [SyncActivityItem] = []
    
    public init() {
        self.config = SynapsConfig.load()
        loadActivities()
    }
    
    public func saveConfig() {
        config.save()
        NASClient.shared.setBaseUrl(config.nasUrl)
    }
    
    public func testConnection() {
        isTestingConnection = true
        connectionStatusMessage = "Pinging NAS..."
        connectionSuccess = nil
        
        saveConfig()
        
        Task {
            let ok = await NASClient.shared.checkHealth()
            isTestingConnection = false
            connectionSuccess = ok
            if ok {
                connectionStatusMessage = "Connected to Synaps NAS successfully!"
            } else {
                connectionStatusMessage = "Cannot reach Synaps NAS at \(config.nasUrl)"
            }
        }
    }
    
    public func loadActivities() {
        recentActivities = LocalCacheStore.shared.getRecentActivities(limit: 100)
    }
    
    public func clearActivities() {
        LocalCacheStore.shared.clearActivityLog()
        loadActivities()
    }
}
