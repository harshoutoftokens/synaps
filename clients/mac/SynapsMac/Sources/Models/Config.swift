import Foundation

public struct SynapsConfig: Codable {
    public var nasUrl: String
    public var macSourceId: String
    public var iphoneSourceId: String
    public var watchFolders: [String]
    public var autoDiscoverNas: Bool
    public var notificationsEnabled: Bool
    
    public static let defaultConfig = SynapsConfig(
        nasUrl: "http://192.168.0.105:8000",
        macSourceId: "mac_harsh",
        iphoneSourceId: "iphone_harsh",
        watchFolders: [
            (FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path) ?? "",
            (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path) ?? "",
            (FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path) ?? "",
            (FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.path) ?? ""
        ].filter { !$0.isEmpty },
        autoDiscoverNas: true,
        notificationsEnabled: true
    )
    
    public static var configDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/synaps", isDirectory: true)
    }
    
    public static var configFile: URL {
        return configDir.appendingPathComponent("mac_app_config.json")
    }
    
    public static func load() -> SynapsConfig {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configFile),
           let cfg = try? JSONDecoder().decode(SynapsConfig.self, from: data) {
            return cfg
        }
        let def = defaultConfig
        def.save()
        return def
    }
    
    public func save() {
        try? FileManager.default.createDirectory(at: Self.configDir, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: Self.configFile)
        }
    }
}
