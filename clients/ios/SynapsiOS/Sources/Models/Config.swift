import Foundation

public struct SynapsConfig: Codable, Equatable, Sendable {
    public var nasUrl: String
    public var sourceId: String
    public var friendlyName: String
    public var autoSyncOnWifi: Bool
    public var requireCharging: Bool
    public var syncFavoritesOnly: Bool
    public var backgroundTaskEnabled: Bool
    public var notificationsEnabled: Bool
    public var lastSyncTimestamp: Date?
    /// Also back up the edited render (e.g. IMG_E1234.HEIC) of photos/videos edited in Photos.
    /// The unmodified original is always backed up.
    public var uploadEditedVersions: Bool
    /// Back up the motion (.MOV) half of Live Photos alongside the still image.
    public var uploadLivePhotoVideos: Bool
    
    public init(
        nasUrl: String,
        sourceId: String,
        friendlyName: String,
        autoSyncOnWifi: Bool,
        requireCharging: Bool,
        syncFavoritesOnly: Bool,
        backgroundTaskEnabled: Bool,
        notificationsEnabled: Bool,
        lastSyncTimestamp: Date?,
        uploadEditedVersions: Bool = true,
        uploadLivePhotoVideos: Bool = true
    ) {
        self.nasUrl = nasUrl
        self.sourceId = sourceId
        self.friendlyName = friendlyName
        self.autoSyncOnWifi = autoSyncOnWifi
        self.requireCharging = requireCharging
        self.syncFavoritesOnly = syncFavoritesOnly
        self.backgroundTaskEnabled = backgroundTaskEnabled
        self.notificationsEnabled = notificationsEnabled
        self.lastSyncTimestamp = lastSyncTimestamp
        self.uploadEditedVersions = uploadEditedVersions
        self.uploadLivePhotoVideos = uploadLivePhotoVideos
    }
    
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
    
    private enum CodingKeys: String, CodingKey {
        case nasUrl, sourceId, friendlyName, autoSyncOnWifi, requireCharging, syncFavoritesOnly
        case backgroundTaskEnabled, notificationsEnabled, lastSyncTimestamp
        case uploadEditedVersions, uploadLivePhotoVideos
    }
    
    /// Tolerant decoding: every field falls back to its default when missing or of the wrong type,
    /// so adding a field in a new app version never invalidates (and silently resets) saved settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynapsConfig.defaultConfig
        nasUrl = (try? c.decodeIfPresent(String.self, forKey: .nasUrl)) ?? d.nasUrl
        sourceId = (try? c.decodeIfPresent(String.self, forKey: .sourceId)) ?? d.sourceId
        friendlyName = (try? c.decodeIfPresent(String.self, forKey: .friendlyName)) ?? d.friendlyName
        autoSyncOnWifi = (try? c.decodeIfPresent(Bool.self, forKey: .autoSyncOnWifi)) ?? d.autoSyncOnWifi
        requireCharging = (try? c.decodeIfPresent(Bool.self, forKey: .requireCharging)) ?? d.requireCharging
        syncFavoritesOnly = (try? c.decodeIfPresent(Bool.self, forKey: .syncFavoritesOnly)) ?? d.syncFavoritesOnly
        backgroundTaskEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .backgroundTaskEnabled)) ?? d.backgroundTaskEnabled
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        lastSyncTimestamp = try? c.decodeIfPresent(Date.self, forKey: .lastSyncTimestamp)
        uploadEditedVersions = (try? c.decodeIfPresent(Bool.self, forKey: .uploadEditedVersions)) ?? d.uploadEditedVersions
        uploadLivePhotoVideos = (try? c.decodeIfPresent(Bool.self, forKey: .uploadLivePhotoVideos)) ?? d.uploadLivePhotoVideos
    }
    
    private static let userDefaultsKey = "synaps_ios_config"
    private static let lock = NSLock()
    
    public static func load() -> SynapsConfig {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }
    
    public func save() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        saveUnlocked()
    }
    
    /// Atomic read-modify-write. Use this instead of load()+save() so concurrent writers
    /// (Settings UI, sync engine) don't overwrite each other's fields with stale copies.
    @discardableResult
    public static func update(_ mutate: (inout SynapsConfig) -> Void) -> SynapsConfig {
        lock.lock()
        defer { lock.unlock() }
        var cfg = loadUnlocked()
        mutate(&cfg)
        cfg.saveUnlocked()
        return cfg
    }
    
    private static func loadUnlocked() -> SynapsConfig {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            let def = defaultConfig
            def.saveUnlocked()
            return def
        }
        if let cfg = try? JSONDecoder().decode(SynapsConfig.self, from: data) {
            return cfg
        }
        // Unreadable blob: run with defaults but leave the stored bytes alone instead of
        // overwriting the user's settings (they are only replaced once the user edits a setting).
        return defaultConfig
    }
    
    private func saveUnlocked() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }
}
