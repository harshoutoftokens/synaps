import Foundation
import XCTest
@testable import SynapsMac

final class ConfigTests: SynapsTestCase {
    override func tearDown() {
        try? FileManager.default.removeItem(at: SynapsConfig.configFile)
        try? FileManager.default.removeItem(at: SynapsConfig.configFile.appendingPathExtension("corrupt"))
        super.tearDown()
    }
    
    func testConfigDirIsIsolatedFromTheRealOne() {
        let real = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/synaps").path
        XCTAssertNotEqual(SynapsConfig.configDir.path, real)
        XCTAssertEqual(SynapsConfig.configDir.path, TestEnvironment.configDir.path)
    }
    
    /// A config written before `apiToken` existed must keep the user's settings (it used to fail to
    /// decode and be silently replaced by the defaults).
    func testLegacyConfigWithoutTokenKeepsSettings() throws {
        let legacy = """
        {"nasUrl":"http://10.0.0.7:8000","macSourceId":"mac_other","iphoneSourceId":"iphone_other",
         "watchFolders":["/Users/x/Movies"],"autoDiscoverNas":false,"notificationsEnabled":false}
        """
        let cfg = try JSONDecoder().decode(SynapsConfig.self, from: Data(legacy.utf8))
        XCTAssertEqual(cfg.nasUrl, "http://10.0.0.7:8000")
        XCTAssertEqual(cfg.macSourceId, "mac_other")
        XCTAssertEqual(cfg.watchFolders, ["/Users/x/Movies"])
        XCTAssertFalse(cfg.autoDiscoverNas)
        XCTAssertFalse(cfg.notificationsEnabled)
        XCTAssertEqual(cfg.apiToken, "")
    }
    
    func testMissingOrMistypedFieldsFallBackIndividually() throws {
        let partial = #"{"nasUrl":"http://10.0.0.9:8000","autoDiscoverNas":"yes","apiToken":"s3cret"}"#
        let cfg = try JSONDecoder().decode(SynapsConfig.self, from: Data(partial.utf8))
        XCTAssertEqual(cfg.nasUrl, "http://10.0.0.9:8000")
        XCTAssertEqual(cfg.apiToken, "s3cret")
        XCTAssertEqual(cfg.autoDiscoverNas, SynapsConfig.defaultConfig.autoDiscoverNas)
        XCTAssertEqual(cfg.macSourceId, SynapsConfig.defaultConfig.macSourceId)
    }
    
    func testSaveIsOwnerOnlyAndRoundTrips() throws {
        var cfg = SynapsConfig.defaultConfig
        cfg.nasUrl = "http://10.1.2.3:8000"
        cfg.apiToken = "token-123"
        XCTAssertTrue(cfg.save())
        
        let attrs = try FileManager.default.attributesOfItem(atPath: SynapsConfig.configFile.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(mode & 0o777, 0o600, "config holds the API token and must be owner-only")
        
        let loaded = SynapsConfig.load()
        XCTAssertEqual(loaded.nasUrl, "http://10.1.2.3:8000")
        XCTAssertEqual(loaded.apiToken, "token-123")
        
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: SynapsConfig.configDir.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "atomic save must not leave temp files behind")
    }
    
    func testCorruptConfigIsBackedUpBeforeReset() throws {
        try FileManager.default.createDirectory(at: SynapsConfig.configDir, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: SynapsConfig.configFile)
        let cfg = SynapsConfig.load()
        XCTAssertEqual(cfg.nasUrl, SynapsConfig.defaultConfig.nasUrl)
        let backup = try Data(contentsOf: SynapsConfig.configFile.appendingPathExtension("corrupt"))
        XCTAssertEqual(String(decoding: backup, as: UTF8.self), "{ not json")
    }
    
    func testNormalizedURLString() {
        XCTAssertEqual(SynapsConfig.normalizedURLString(" 192.168.0.105:8000/ "), "http://192.168.0.105:8000")
        XCTAssertEqual(SynapsConfig.normalizedURLString("https://nas.local:8443//"), "https://nas.local:8443")
        XCTAssertEqual(SynapsConfig.normalizedURLString(""), "")
    }
}

final class DateParsingTests: SynapsTestCase {
    private func components(_ date: Date?, in zone: TimeZone) -> DateComponents? {
        guard let date = date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
    }
    
    func testNaiveTimestampsAreLocalTime() {
        let parsed = components(AppViewModel.parseDate("2026-10-13T14:59:00"), in: .current)
        XCTAssertEqual(parsed?.year, 2026)
        XCTAssertEqual(parsed?.hour, 14)
        XCTAssertEqual(parsed?.minute, 59)
        
        // Whole-second and fractional naive values must be read the same way
        let whole = AppViewModel.parseDate("2026-10-13T14:59:00")
        let fractional = AppViewModel.parseDate("2026-10-13T14:59:00.250000")
        XCTAssertNotNil(whole)
        XCTAssertEqual(fractional!.timeIntervalSince(whole!), 0.25, accuracy: 0.001)
        XCTAssertNotNil(AppViewModel.parseDate("2026-10-13 14:59:00"))
        XCTAssertNotNil(AppViewModel.parseDate("2026-10-13"))
    }
    
    func testZonedTimestamps() {
        let utc = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(components(AppViewModel.parseDate("2026-10-13T09:29:00Z"), in: utc)?.hour, 9)
        XCTAssertEqual(components(AppViewModel.parseDate("2026-10-13T14:59:00+05:30"), in: utc)?.hour, 9)
        XCTAssertEqual(components(AppViewModel.parseDate("2026-10-13T14:59:00+0530"), in: utc)?.minute, 29)
        XCTAssertEqual(components(AppViewModel.parseDate("2026-10-13T14:59:00.123456789-04:00"), in: utc)?.hour, 18)
    }
    
    func testGarbageNeverThrowsOrCrashes() {
        for value in [nil, "", "yesterday", "2026-13-40T99:99:99", "2026-10-13T", "13/10/2026"] {
            XCTAssertNil(AppViewModel.parseDate(value), "\(String(describing: value))")
        }
    }
    
    func testUploadTimestampsAvoidZSuffix() {
        // Python < 3.11 datetime.fromisoformat() rejects "Z"
        XCTAssertEqual(NASClient.timestampString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00+00:00")
    }
}
