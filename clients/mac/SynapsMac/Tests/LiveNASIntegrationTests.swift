import Foundation
import CryptoKit
import XCTest
@testable import SynapsMac

/// End-to-end checks against a running backend. Skipped unless SYNAPS_LIVE_NAS_URL is set, e.g.
///
///     SYNAPS_LIVE_NAS_URL=http://127.0.0.1:8000 [SYNAPS_LIVE_NAS_TOKEN=...] swift test --filter LiveNAS
///
/// Point it at a local/disposable backend: the tests upload small random files under a throwaway
/// source ("synapstest-<random>", friendly name "SynapsTests", platform "SynapsTest", so mirrors land
/// in Mirrors/SynapsTests/ rather than the real Mac mirror). Set SYNAPS_LIVE_NAS_EXPECT_STREAM=1 to
/// require that uploads use PUT /api/v2/ingest/stream.
final class LiveNASIntegrationTests: SynapsTestCase {
    private var baseUrl = ""
    private var token = ""
    private let sourceId = "synapstest-" + String(UUID().uuidString.prefix(8)).lowercased()
    private let friendlyName = "SynapsTests"
    private let platform = "SynapsTest"
    
    override func setUpWithError() throws {
        try super.setUpWithError()
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SYNAPS_LIVE_NAS_URL"], !url.isEmpty else {
            throw XCTSkip("Set SYNAPS_LIVE_NAS_URL to run live NAS integration tests")
        }
        baseUrl = SynapsConfig.normalizedURLString(url)
        token = env["SYNAPS_LIVE_NAS_TOKEN"] ?? ""
    }
    
    private func client(token: String? = nil) -> NASClient {
        return NASClient(baseUrl: baseUrl, apiToken: token ?? self.token, reportsAuthFailures: false)
    }
    
    private func randomFile(_ name: String, bytes: Int = 256 * 1024, in dir: URL? = nil) -> SynapsFileItem {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                arc4random_buf(base, buffer.count)
            }
        }
        let folder = dir ?? TestEnvironment.makeTempDir("live")
        let url = TestEnvironment.writeFile(folder.appendingPathComponent(name), data)
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return TestEnvironment.fileItem(for: url, sha256: sha, sourceId: sourceId)
    }
    
    /// The check endpoint registers the throwaway source with an isolated name/platform before any
    /// upload could auto-register it as a Mac source.
    private func registerSource(_ client: NASClient) async throws {
        let probe = SynapsFileItem(id: "/synaps-tests/probe", originalPath: "/synaps-tests/probe", filename: "probe",
                                   fileSize: 1, sourceLocation: "Tests", modifiedAt: Date(), sha256: String(repeating: "f", count: 64), sourceId: sourceId)
        _ = try await client.batchPreCheck(sourceId: sourceId, friendlyName: friendlyName, platform: platform, items: [probe])
    }
    
    func testHealthAndAuth() async throws {
        let nas = client()
        let healthy = await nas.checkHealth()
        XCTAssertTrue(healthy, "\(baseUrl)/api/health should answer {\"status\":\"ok\"}")
        let accepted = await nas.verifyAuth()
        XCTAssertEqual(accepted, true, "authenticated request with the configured token")
        if !token.isEmpty {
            let anonymous = await client(token: "").verifyAuth()
            XCTAssertEqual(anonymous, false, "with SYNAPS_API_TOKEN set, a request without the token must get 401")
        }
        _ = try await nas.browseDirectory(path: "", page: 1, perPage: 50)
    }
    
    func testUploadThenDeduplicate() async throws {
        let nas = client()
        try await registerSource(nas)
        // "+", "&", "#" and "%" must reach the server intact (a "+" used to arrive as a space)
        let name = "live C++ & notes #1 100%.bin"
        let item = randomFile(name, bytes: 3 * 1024 * 1024)
        
        let before = try await nas.batchPreCheck(sourceId: sourceId, friendlyName: friendlyName, platform: platform, items: [item])
        XCTAssertEqual(before.results.first?.status, "need_upload")
        
        let result = try await nas.uploadFile(item: item, sourceId: sourceId)
        XCTAssertEqual(result.status, "success")
        XCTAssertEqual(result.sha256, item.sha256)
        if let mirror = result.mirrorPath {
            XCTAssertTrue(mirror.hasSuffix(name), "mirror path \(mirror) should end with the exact file name")
        }
        print("ℹ️ live upload used \(result.usedStreamEndpoint ? "PUT /api/v2/ingest/stream" : "multipart POST /api/v2/ingest/upload")")
        if ProcessInfo.processInfo.environment["SYNAPS_LIVE_NAS_EXPECT_STREAM"] == "1" {
            XCTAssertTrue(result.usedStreamEndpoint)
        }
        
        // Same content under another path is linked without a transfer
        let copy = SynapsFileItem(id: item.originalPath + ".copy", originalPath: item.originalPath + ".copy", filename: "live-upload-copy.bin",
                              fileSize: item.fileSize, sourceLocation: item.sourceLocation, modifiedAt: item.modifiedAt,
                              sha256: item.sha256, sourceId: sourceId)
        let after = try await nas.batchPreCheck(sourceId: sourceId, friendlyName: friendlyName, platform: platform, items: [item, copy])
        XCTAssertEqual(after.results.map { $0.status }, ["dedup_linked", "dedup_linked"])
    }
    
    func testMultipartFallbackStillWorks() async throws {
        let nas = client()
        try await registerSource(nas)
        nas.overrideStreamUploadSupport(false)
        let item = randomFile("live-multipart.bin")
        let result = try await nas.uploadFile(item: item, sourceId: sourceId)
        XCTAssertEqual(result.status, "success")
        XCTAssertFalse(result.usedStreamEndpoint)
        XCTAssertEqual(result.sha256, item.sha256)
    }
    
    func testChecksumMismatchIsRejected() async throws {
        let nas = client()
        try await registerSource(nas)
        var item = randomFile("live-mismatch.bin", bytes: 4096)
        item.sha256 = String(repeating: "0", count: 64)
        do {
            _ = try await nas.uploadFile(item: item, sourceId: sourceId)
            XCTFail("the server must reject a wrong client_sha256")
        } catch let error as NASClientError {
            XCTAssertTrue(error.isChecksumMismatch, "\(error)")
        }
    }
    
    func testPreCheckBatchesLargeRequests() async throws {
        let nas = client()
        let items = (0..<450).map { i -> SynapsFileItem in
            let sha = SHA256.hash(data: Data("\(sourceId)-\(i)-\(UUID().uuidString)".utf8)).map { String(format: "%02x", $0) }.joined()
            return SynapsFileItem(id: "/synaps-tests/batch/\(i)", originalPath: "/synaps-tests/batch/\(i)", filename: "\(i)",
                                  fileSize: 1, sourceLocation: "Tests", modifiedAt: Date(), sha256: sha, sourceId: sourceId)
        }
        let response = try await nas.batchPreCheck(sourceId: sourceId, friendlyName: friendlyName, platform: platform, items: items)
        XCTAssertEqual(response.results.count, 450)
        XCTAssertTrue(response.results.allSatisfy { $0.status == "need_upload" })
    }
    
    func testSyncEngineAndAlbumSync() async throws {
        let nas = client()
        try await registerSource(nas)
        let dir = TestEnvironment.makeTempDir("live-engine")
        let a = randomFile("a.bin", in: dir)
        let b = randomFile("b.bin", in: dir)
        var items = [a, b].map { item -> SynapsFileItem in
            var copy = item
            copy.albumName = "SynapsTests Album"
            copy.sha256 = nil // let the engine hash them
            return copy
        }
        // Same bytes as `a` at another path
        let dupURL = dir.appendingPathComponent("a-duplicate.bin")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: a.originalPath), to: dupURL)
        items.append(TestEnvironment.fileItem(for: dupURL, album: "SynapsTests Album", sourceId: sourceId))
        
        var options = SyncEngine.Options()
        options.friendlyName = friendlyName
        options.platform = platform
        let store = TestEnvironment.makeCacheStore()
        let engine = SyncEngine(client: nas, cacheStore: store)
        
        let first = await engine.run(items: items, options: options) { _ in }
        XCTAssertEqual(first.committed, 3)
        XCTAssertEqual(first.uploaded, 2, "the duplicate of a.bin is linked, not uploaded again")
        XCTAssertEqual(first.failed, 0)
        XCTAssertFalse(store.getRecentActivity().contains { $0.eventType == .syncFailed }, "\(store.getRecentActivity().map { $0.details })")
        
        let second = await engine.run(items: items, options: options) { _ in }
        XCTAssertEqual(second.alreadyOnNAS, 3, "re-syncing known content must not transfer it again")
        
        try await nas.syncAlbums(sourceId: sourceId, albumName: "SynapsTests Album", originalPaths: items.map { $0.originalPath })
    }
}
