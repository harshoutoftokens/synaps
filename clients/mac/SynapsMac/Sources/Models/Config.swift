import Foundation

public struct SynapsConfig: Codable, Sendable {
    public var nasUrl: String
    public var macSourceId: String
    public var iphoneSourceId: String
    public var watchFolders: [String]
    public var autoDiscoverNas: Bool
    public var notificationsEnabled: Bool
    /// Optional shared secret for backends started with SYNAPS_API_TOKEN.
    /// Sent as `Authorization: Bearer <token>`; empty means the NAS has no auth.
    public var apiToken: String
    
    public init(
        nasUrl: String,
        macSourceId: String,
        iphoneSourceId: String,
        watchFolders: [String],
        autoDiscoverNas: Bool,
        notificationsEnabled: Bool,
        apiToken: String = ""
    ) {
        self.nasUrl = nasUrl
        self.macSourceId = macSourceId
        self.iphoneSourceId = iphoneSourceId
        self.watchFolders = watchFolders
        self.autoDiscoverNas = autoDiscoverNas
        self.notificationsEnabled = notificationsEnabled
        self.apiToken = apiToken
    }
    
    private enum CodingKeys: String, CodingKey {
        case nasUrl, macSourceId, iphoneSourceId, watchFolders, autoDiscoverNas, notificationsEnabled, apiToken
    }
    
    /// Every field falls back to its default, so a config written by an older build (or missing a
    /// field added later) keeps the user's settings instead of failing to decode and being reset.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynapsConfig.defaultConfig
        nasUrl = (try? c.decodeIfPresent(String.self, forKey: .nasUrl)) ?? d.nasUrl
        macSourceId = (try? c.decodeIfPresent(String.self, forKey: .macSourceId)) ?? d.macSourceId
        iphoneSourceId = (try? c.decodeIfPresent(String.self, forKey: .iphoneSourceId)) ?? d.iphoneSourceId
        watchFolders = (try? c.decodeIfPresent([String].self, forKey: .watchFolders)) ?? d.watchFolders
        autoDiscoverNas = (try? c.decodeIfPresent(Bool.self, forKey: .autoDiscoverNas)) ?? d.autoDiscoverNas
        notificationsEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled)) ?? d.notificationsEnabled
        apiToken = (try? c.decodeIfPresent(String.self, forKey: .apiToken)) ?? d.apiToken
    }
    
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
        notificationsEnabled: true,
        apiToken: ""
    )
    
    /// Posted (with the new config as `object`) after the user saves Settings.
    public static let didChangeNotification = Notification.Name("SynapsConfigDidChange")
    
    /// Under XCTest the real ~/.config/synaps must never be touched, even if a test forgets to
    /// set SYNAPS_CONFIG_DIR.
    private static let isRunningUnderTests: Bool = NSClassFromString("XCTestCase") != nil
    
    public static var configDir: URL {
        if let override = ProcessInfo.processInfo.environment["SYNAPS_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isRunningUnderTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("synaps-tests-\(getpid())", isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/synaps", isDirectory: true)
    }
    
    public static var configFile: URL {
        return configDir.appendingPathComponent("mac_app_config.json")
    }
    
    /// Normalizes user input like "192.168.0.105:8000/" to "http://192.168.0.105:8000".
    public static func normalizedURLString(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty && !s.contains("://") {
            s = "http://" + s
        }
        while s.hasSuffix("/") {
            s.removeLast()
        }
        return s
    }
    
    public static func load() -> SynapsConfig {
        let file = configFile
        guard let data = try? Data(contentsOf: file) else {
            let def = defaultConfig
            if !FileManager.default.fileExists(atPath: file.path) {
                def.save()
            }
            return def
        }
        do {
            let cfg = try JSONDecoder().decode(SynapsConfig.self, from: data)
            if !cfg.apiToken.isEmpty {
                restrictPermissions(of: file)
            }
            return cfg
        } catch {
            // Malformed JSON: keep a copy so the user's settings aren't silently lost, then reset.
            let backup = file.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: file, to: backup)
            print("⚠️ [Config] \(file.path) could not be decoded (\(error)); backed up to \(backup.lastPathComponent)")
            let def = defaultConfig
            def.save()
            return def
        }
    }
    
    /// Writes the config atomically with owner-only (0600) permissions, since it may hold the API token.
    @discardableResult
    public func save() -> Bool {
        let dir = Self.configDir
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            print("❌ [Config] Cannot create \(dir.path): \(error.localizedDescription)")
            return false
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return false }
        return Self.writeOwnerOnly(data, to: Self.configFile)
    }
    
    /// Creates a temp file with mode 0600 (never briefly world-readable), fsyncs it and renames it
    /// over the destination.
    static func writeOwnerOnly(_ data: Data, to url: URL) -> Bool {
        let tmpPath = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let fd = open(tmpPath, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            print("❌ [Config] Cannot write \(tmpPath): errno \(errno)")
            return false
        }
        var ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, base + offset, buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        if ok {
            ok = fsync(fd) == 0
        }
        close(fd)
        if ok {
            ok = rename(tmpPath, url.path) == 0
        }
        if !ok {
            unlink(tmpPath)
            print("❌ [Config] Failed to save \(url.path): errno \(errno)")
        } else {
            restrictPermissions(of: url)
        }
        return ok
    }
    
    private static func restrictPermissions(of url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mode = (attrs[.posixPermissions] as? NSNumber)?.int16Value,
              mode & 0o077 != 0 else { return }
        chmod(url.path, 0o600)
    }
}
