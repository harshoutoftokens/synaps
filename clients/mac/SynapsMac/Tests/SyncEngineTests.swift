import Foundation
import CryptoKit
import XCTest
@testable import SynapsMac

final class SyncEngineTests: SynapsTestCase {
    private static let success: [String: Any] = ["status": "success", "physical_object_id": "p", "logical_item_id": "l", "sha256": "s"]
    
    private func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    private func makeFiles(_ count: Int, prefix: String = "file", album: String? = nil) -> [SynapsFileItem] {
        let dir = TestEnvironment.makeTempDir("sync")
        return (0..<count).map { i in
            let url = TestEnvironment.writeFile(dir.appendingPathComponent("\(prefix)\(i).bin"), Data("\(prefix) \(i) payload".utf8))
            return TestEnvironment.fileItem(for: url, album: album)
        }
    }
    
    private func options() -> SyncEngine.Options {
        var options = SyncEngine.Options()
        options.retryBaseDelay = 0.01
        return options
    }
    
    /// Answers the pre-check with `dedup` for the given paths and need_upload for the rest.
    private func checkResponse(_ req: StubURLProtocol.Request, dedup: Set<String>) -> StubURLProtocol.Response {
        let files = (req.json?["files"] as? [[String: Any]]) ?? []
        let results = files.map { f -> [String: Any] in
            let path = f["original_path"] as! String
            return ["original_path": path, "status": dedup.contains(path) ? "dedup_linked" : "need_upload"]
        }
        return .json(["source_id": "mac_test", "results": results])
    }
    
    func testDedupUploadAndFailureOutcomes() async throws {
        let items = makeFiles(3)
        let store = TestEnvironment.makeCacheStore()
        let dedupPath = items[0].originalPath
        let failingName = items[2].filename
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [dedupPath])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"):
                return req.query["original_filename"] == failingName
                    ? .json(["detail": "Upload stream error: disk full"], status: 500)
                    : .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let engine = SyncEngine(client: makeClient(), cacheStore: store)
        let finished = ResultCollector()
        let summary = await engine.run(items: items, options: options()) { event in
            if case .finished(let results) = event {
                finished.append(results)
            }
        }
        
        XCTAssertEqual(summary.alreadyOnNAS, 1)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(finished.count, 3, "every item gets exactly one outcome")
        XCTAssertEqual(store.getRecord(for: items[0].originalPath)?.syncStatus, SyncStatus.committed.rawValue)
        XCTAssertEqual(store.getRecord(for: items[1].originalPath)?.syncStatus, SyncStatus.committed.rawValue)
        XCTAssertNil(store.getRecord(for: items[2].originalPath))
        XCTAssertTrue(store.getRecentActivity().contains { $0.eventType == .syncFailed && $0.details.contains("HTTP 500: Upload stream error: disk full") },
                      "upload failures are logged with the server's detail")
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.method == "PUT" }.count, 2, "500 is not retried")
    }
    
    func testIdenticalContentIsUploadedOnce() async throws {
        let dir = TestEnvironment.makeTempDir("dups")
        let original = TestEnvironment.writeFile(dir.appendingPathComponent("IMG_1.JPG"), Data("same bytes".utf8))
        let copy = TestEnvironment.writeFile(dir.appendingPathComponent("IMG_1 copy.JPG"), Data("same bytes".utf8))
        let items = [TestEnvironment.fileItem(for: original), TestEnvironment.fileItem(for: copy)]
        let uploaded = UploadedHashes()
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"):
                let files = (req.json?["files"] as? [[String: Any]]) ?? []
                let results = files.map { f -> [String: Any] in
                    let known = uploaded.contains(f["client_sha256"] as? String ?? "")
                    return ["original_path": f["original_path"] as! String, "status": known ? "dedup_linked" : "need_upload"]
                }
                return .json(["results": results])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"):
                uploaded.insert(req.query["client_sha256"] ?? "")
                return .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let store = TestEnvironment.makeCacheStore()
        let summary = await SyncEngine(client: makeClient(), cacheStore: store)
            .run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.alreadyOnNAS, 1)
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.method == "PUT" }.count, 1)
        XCTAssertTrue(store.getRecentActivity().contains { $0.eventType == .existingDiscovered && $0.filePath == copy.path },
                      "the linked copy is logged like any other dedup-linked file")
        XCTAssertEqual(store.getRecord(for: copy.path)?.syncStatus, SyncStatus.committed.rawValue)
    }
    
    func testOther400FailsWithoutRetryWhenContentUnchanged() async {
        let items = makeFiles(1)
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(["detail": "Invalid Content-Length"], status: 400)
            default: return Response(status: 500)
            }
        }
        let store = TestEnvironment.makeCacheStore()
        let summary = await SyncEngine(client: makeClient(), cacheStore: store).run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.method == "PUT" }.count, 1, "unchanged content is not re-sent")
        XCTAssertTrue(store.getRecentActivity().contains { $0.details.contains("HTTP 400: Invalid Content-Length") })
    }
    
    func testUploadsRunAtMostTwoAtATime() async {
        let items = makeFiles(6)
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(Self.success, delay: 0.15)
            default: return Response(status: 500)
            }
        }
        let engine = SyncEngine(client: makeClient(), cacheStore: TestEnvironment.makeCacheStore())
        let summary = await engine.run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.uploaded, 6)
        XCTAssertEqual(StubURLProtocol.maxConcurrent(path: "/api/v2/ingest/stream"), 2)
    }
    
    func testTransientErrorsAreRetriedWithBackoff() async {
        let items = makeFiles(1)
        let attempts = AttemptCounter()
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"):
                return attempts.next() == 1 ? .json(["detail": "busy"], status: 503) : .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let summary = await SyncEngine(client: makeClient(), cacheStore: TestEnvironment.makeCacheStore())
            .run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(attempts.value, 2)
    }
    
    func testChecksumMismatchRehashesAndRetriesOnce() async throws {
        var items = makeFiles(1)
        items[0].sha256 = String(repeating: "0", count: 64) // stale hash from before an edit
        let realSha = sha256Hex(try Data(contentsOf: URL(fileURLWithPath: items[0].originalPath)))
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"):
                return req.query["client_sha256"] == realSha
                    ? .json(Self.success)
                    : .json(["detail": "SHA-256 mismatch: client=000, computed=\(realSha)"], status: 400)
            default: return Response(status: 500)
            }
        }
        let summary = await SyncEngine(client: makeClient(), cacheStore: TestEnvironment.makeCacheStore())
            .run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(StubURLProtocol.recorded.filter { $0.method == "PUT" }.map { $0.query["client_sha256"] },
                       [String(repeating: "0", count: 64), realSha])
    }
    
    func testUnauthorizedStopsTheRun() async {
        let items = makeFiles(3)
        StubURLProtocol.setHandler { _ in .json(["detail": "unauthorized"], status: 401) }
        let summary = await SyncEngine(client: makeClient(token: "bad"), cacheStore: TestEnvironment.makeCacheStore())
            .run(items: items, options: options()) { _ in }
        XCTAssertTrue(summary.unauthorized)
        XCTAssertEqual(summary.failed, 3)
        XCTAssertFalse(StubURLProtocol.recorded.contains { $0.method == "PUT" || $0.path == "/api/v2/ingest/upload" })
    }
    
    func testDiskFullStopsTheBatchWithoutRetries() async {
        let items = makeFiles(5)
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(["detail": "Not enough space on the NAS"], status: 507)
            default: return Response(status: 500)
            }
        }
        let store = TestEnvironment.makeCacheStore()
        let summary = await SyncEngine(client: makeClient(), cacheStore: store).run(items: items, options: options()) { _ in }
        XCTAssertTrue(summary.diskFull)
        XCTAssertEqual(summary.failed, 5)
        XCTAssertLessThanOrEqual(StubURLProtocol.recorded.filter { $0.method == "PUT" }.count, 2, "only the uploads already in flight hit the full disk")
        XCTAssertEqual(store.getRecentActivity().filter { $0.details.hasPrefix("Sync stopped: Home Cloud's disk is full") }.count, 1)
    }
    
    func testCancellationStopsPromptly() async {
        let items = makeFiles(8)
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(Self.success, delay: 0.3)
            default: return Response(status: 500)
            }
        }
        let engine = SyncEngine(client: makeClient(), cacheStore: TestEnvironment.makeCacheStore())
        let opts = options()
        let task = Task { await engine.run(items: items, options: opts) { _ in } }
        try? await Task.sleep(nanoseconds: 150_000_000)
        task.cancel()
        let summary = await task.value
        XCTAssertGreaterThan(summary.cancelled, 0)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertEqual(summary.uploaded + summary.cancelled, 8)
        XCTAssertLessThan(StubURLProtocol.recorded.filter { $0.method == "PUT" }.count, 8)
    }
    
    func testAlbumMembershipIsSyncedAndFailuresLogged() async throws {
        let items = makeFiles(2, prefix: "trip", album: "Trip")
        let store = TestEnvironment.makeCacheStore()
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("POST", "/api/v2/ingest/check"): return self.checkResponse(req, dedup: [items[0].originalPath])
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(Self.success)
            case ("POST", "/api/v2/ingest/albums"): return .json(["detail": "Source not found"], status: 404)
            default: return Response(status: 500)
            }
        }
        let summary = await SyncEngine(client: makeClient(), cacheStore: store).run(items: items, options: options()) { _ in }
        XCTAssertEqual(summary.committed, 2)
        
        let albumCall = try XCTUnwrap(StubURLProtocol.recorded.first { $0.path == "/api/v2/ingest/albums" })
        XCTAssertEqual(albumCall.json?["album_name"] as? String, "Trip")
        XCTAssertEqual(Set(albumCall.json?["original_paths"] as? [String] ?? []), Set(items.map { $0.originalPath }))
        XCTAssertTrue(store.getRecentActivity().contains { $0.details.contains("Album sync failed for \"Trip\"") && $0.details.contains("Source not found") })
    }
}

private final class ResultCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SyncEngine.ItemResult] = []
    
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }
    
    func append(_ more: [SyncEngine.ItemResult]) {
        lock.lock()
        results.append(contentsOf: more)
        lock.unlock()
    }
}

private final class UploadedHashes: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes = Set<String>()
    
    func insert(_ hash: String) {
        lock.lock()
        hashes.insert(hash)
        lock.unlock()
    }
    
    func contains(_ hash: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hashes.contains(hash)
    }
}

private final class AttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}
