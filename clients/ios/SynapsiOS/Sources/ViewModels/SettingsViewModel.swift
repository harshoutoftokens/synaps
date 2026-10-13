import SwiftUI
import Combine

@MainActor
public final class SettingsViewModel: ObservableObject {
    @Published public var config: SynapsConfig
    /// Optional NAS API token (SYNAPS_API_TOKEN on the server); stored in the Keychain.
    @Published public var apiToken: String
    @Published public private(set) var tokenSaveFailed: Bool = false
    @Published public var isTestingConnection: Bool = false
    @Published public var connectionStatusMessage: String = ""
    @Published public var connectionSuccess: Bool? = nil
    @Published public var recentActivities: [SyncActivityItem] = []
    
    public init() {
        self.config = SynapsConfig.load()
        self.apiToken = APITokenStore.token() ?? ""
        loadActivities()
    }
    
    /// Persists the user-editable fields with an atomic read-modify-write, so fields written
    /// elsewhere (e.g. lastSyncTimestamp by the sync engine) aren't overwritten by this copy.
    public func saveConfig() {
        let edited = config
        let saved = SynapsConfig.update { cfg in
            cfg.nasUrl = edited.nasUrl
            cfg.sourceId = edited.sourceId
            cfg.friendlyName = edited.friendlyName
            cfg.autoSyncOnWifi = edited.autoSyncOnWifi
            cfg.requireCharging = edited.requireCharging
            cfg.syncFavoritesOnly = edited.syncFavoritesOnly
            cfg.backgroundTaskEnabled = edited.backgroundTaskEnabled
            cfg.notificationsEnabled = edited.notificationsEnabled
            cfg.uploadEditedVersions = edited.uploadEditedVersions
            cfg.uploadLivePhotoVideos = edited.uploadLivePhotoVideos
        }
        if saved.lastSyncTimestamp != config.lastSyncTimestamp {
            config.lastSyncTimestamp = saved.lastSyncTimestamp
        }
    }
    
    /// Auto-upload / background / charging toggles: persist and (re)schedule or cancel BG tasks.
    public func automationSettingsChanged() {
        saveConfig()
        BackgroundSyncWorker.shared.scheduleNextBackgroundSync()
    }
    
    /// Live Photo video / edited version toggles change which files an asset needs on the NAS.
    public func backupContentsChanged() {
        saveConfig()
        PhotoLibraryService.shared.policyDidChange()
    }
    
    public func saveToken() {
        tokenSaveFailed = !APITokenStore.setToken(apiToken)
    }
    
    public var lastSyncDescription: String {
        guard let date = config.lastSyncTimestamp else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
    
    public var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
    
    public func testConnection() {
        isTestingConnection = true
        connectionStatusMessage = "Pinging NAS..."
        connectionSuccess = nil
        
        let normalized = NASClient.normalizeBaseURL(config.nasUrl)
        if normalized != config.nasUrl {
            config.nasUrl = normalized
        }
        saveConfig()
        saveToken()
        
        Task {
            let result = await NASClient.shared.verifyAccess()
            isTestingConnection = false
            switch result {
            case .ok:
                connectionSuccess = true
                connectionStatusMessage = "Connected to Synaps NAS successfully!"
            case .unreachable:
                connectionSuccess = false
                connectionStatusMessage = "Cannot reach Synaps NAS at \(NASClient.shared.getBaseUrl())"
            case .unauthorized:
                connectionSuccess = false
                connectionStatusMessage = APITokenStore.token() == nil
                    ? "The NAS requires an API token. Enter it below."
                    : "The NAS rejected this API token."
            case .failed(let message):
                connectionSuccess = false
                connectionStatusMessage = "NAS reachable but returned an error: \(message)"
            }
            await SyncManager.shared.checkNASStatus()
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
