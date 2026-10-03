import Foundation

public struct SynapsConfig: Codable, Equatable {
    public var nasUrl: String
    public var sourceId: String
    public var friendlyName: String
    public var autoSyncOnWifi: Bool
    public var requireCharging: Bool
    public var syncFavoritesOnly: Bool
    public var backgroundTaskEnabled: Bool
    public var notificationsEnabled: Bool
    public var lastSyncTimestamp: Date?
    
    public static let defaultConfig = SynapsConfig(
        nasUrl: "http://192.168.0.105:8000",
        sourceId: "iphone_harsh",
        friendlyName: "Harsh's iPhone",
        autoSyncOnWifi: true,
        requireCharging: false,
        syncFavoritesOnly: false,
        backgroundTaskEnabled: true,
        notificationsEnabled: true,
        lastSyncTimestamp: nil
    )
    
    private static let userDefaultsKey = "synaps_ios_config"
    
    public static func load() -> SynapsConfig {
        if let data = UserDefaults.standard.data(forKey: userDefaultsKey),
           let cfg = try? JSONDecoder().decode(SynapsConfig.self, from: data) {
            return cfg
        }
        let def = defaultConfig
        def.save()
        return def
    }
    
    public func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
