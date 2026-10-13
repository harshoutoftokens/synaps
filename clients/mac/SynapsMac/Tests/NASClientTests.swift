import Foundation
import CryptoKit
import XCTest
@testable import SynapsMac

final class NASClientTests: SynapsTestCase {
    private static let success: [String: Any] = [
        "status": "success", "physical_object_id": "p1", "logical_item_id": "l1",
        "canonical_path": "Vault/2026/10/x", "mirror_path": "/m/x", "sha256": "abc"
    ]
    
    private func sha256Hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    private func makeUploadItem(_ name: String = "C++ & notes #1.txt", contents: Data = Data("hello nas".utf8)) -> (SynapsFileItem, Data) {
        let url = TestEnvironment.writeFile(TestEnvironment.makeTempDir("upload").appendingPathComponent(name), contents)
        return (TestEnvironment.fileItem(for: url, sha256: sha256Hex(contents)), contents)
    }
    
    // MARK: Auth & request building
    
    func testBearerTokenOnEveryRequestWhenConfigured() async throws {
        StubURLProtocol.setHandler { _ in .json(["current_path": "/", "folders": [], "files": [], "total_folders": 0, "total_files": 0, "page": 1, "per_page": 1000]) }
        _ = try await makeClient(token: "s3cret").browseDirectory(path: "Mirrors")
        XCTAssertEqual(StubURLProtocol.recorded.last?.headers["Authorization"], "Bearer s3cret")
        
        _ = try await makeClient(token: "").browseDirectory(path: "Mirrors")
        XCTAssertNil(StubURLProtocol.recorded.last?.headers["Authorization"])
    }
    
    func testUnauthorizedIsReportedAsSuch() async {
        StubURLProtocol.setHandler { _ in .json(["detail": "unauthorized"], status: 401) }
        do {
            _ = try await makeClient(token: "wrong").browseDirectory(path: "")
            XCTFail("expected 401")
        } catch {
            XCTAssertEqual(error as? NASClientError, .unauthorized)
        }
        let verdict = await makeClient(token: "wrong").verifyAuth()
        XCTAssertEqual(verdict, false)
    }
    
    /// "+" used to reach the backend unescaped and be decoded as a space ("C++" -> "C  ").
    func testQueryValuesSurviveBackendDecoding() async throws {
        let tricky = "Mirrors/Harsh/Mac/C++ & Tom=Jerry #1 100%;é.jpg"
        StubURLProtocol.setHandler { _ in Response(status: 404) }
        _ = try await makeClient().browseDirectory(path: tricky)
        XCTAssertEqual(StubURLProtocol.recorded.last?.query["path"], tricky)
    }
    
    // MARK: Health / discovery
    
    func testHealthCheckNeverSwitchesHostsAndDiscoveryOnlySuggests() async {
        StubURLProtocol.setHandler { req in
            if req.url.host == "192.168.0.101" && req.path == "/api/health" {
                return .json(["status": "ok"])
            }
            return .failure(.cannotConnectToHost)
        }
        let client = makeClient(token: "s3cret", baseUrl: "http://10.9.9.9:8000")
        let online = await client.checkHealth()
        XCTAssertFalse(online)
        XCTAssertEqual(client.getBaseUrl(), "http://10.9.9.9:8000", "a host answering {status: ok} must not be adopted")
        
        let found = await client.discoverNAS()
        XCTAssertEqual(found, ["http://192.168.0.101:8000"])
        XCTAssertEqual(client.getBaseUrl(), "http://10.9.9.9:8000")
        XCTAssertTrue(StubURLProtocol.recorded.allSatisfy { $0.headers["Authorization"] == nil },
                      "the API token must never be sent to unconfirmed hosts")
    }
    
    // MARK: Upload
    
    func testStreamUploadPutsRawFileWithQueryFields() async throws {
        let (item, contents) = makeUploadItem()
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("PUT", "/api/v2/ingest/stream"): return .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let result = try await makeClient(token: "t0k").uploadFile(item: item, sourceId: "mac_test")
        XCTAssertTrue(result.usedStreamEndpoint)
        
        let put = try XCTUnwrap(StubURLProtocol.recorded.first { $0.method == "PUT" })
        XCTAssertEqual(put.body, contents, "body must be the raw file bytes")
        XCTAssertEqual(put.headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(put.headers["Authorization"], "Bearer t0k")
        let q = put.query
        XCTAssertEqual(q["source_id"], "mac_test")
        XCTAssertEqual(q["original_path"], item.originalPath)
        XCTAssertEqual(q["original_filename"], "C++ & notes #1.txt")
        XCTAssertEqual(q["source_location"], "Tests")
        XCTAssertEqual(q["client_sha256"], item.sha256)
        XCTAssertEqual(q["is_favorite"], "false")
        XCTAssertTrue(q["source_modified_at"]?.hasSuffix("+00:00") ?? false)
        XCTAssertTrue(q["source_created_at"]?.hasSuffix("+00:00") ?? false)
        XCTAssertFalse(StubURLProtocol.recorded.contains { $0.path == "/api/v2/ingest/upload" })
    }
    
    func testFallsBackToMultipartWhenStreamRouteIsMissingAndRemembers() async throws {
        let (item, contents) = makeUploadItem("IMG_0001.HEIC")
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("GET", "/api/v2/ingest/stream"): return Response(status: 404)
            case ("POST", "/api/v2/ingest/upload"): return .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let client = makeClient()
        let first = try await client.uploadFile(item: item, sourceId: "mac_test")
        XCTAssertFalse(first.usedStreamEndpoint)
        _ = try await client.uploadFile(item: item, sourceId: "mac_test")
        
        let recorded = StubURLProtocol.recorded
        XCTAssertEqual(recorded.filter { $0.path == "/api/v2/ingest/stream" }.count, 1, "the 404 is remembered for the session")
        XCTAssertEqual(recorded.filter { $0.path == "/api/v2/ingest/upload" }.count, 2)
        
        let post = try XCTUnwrap(recorded.first { $0.method == "POST" })
        let parts = Multipart.parts(of: post.body, contentType: post.headers["Content-Type"])
        XCTAssertEqual(parts["file"], contents)
        XCTAssertEqual(parts["client_sha256"].map { String(decoding: $0, as: UTF8.self) }, item.sha256)
        XCTAssertEqual(parts["original_filename"].map { String(decoding: $0, as: UTF8.self) }, "IMG_0001.HEIC")
        XCTAssertEqual(parts["source_id"].map { String(decoding: $0, as: UTF8.self) }, "mac_test")
    }
    
    func testFallsBackWhenPutAnswers405() async throws {
        let (item, _) = makeUploadItem("clip.mov")
        StubURLProtocol.setHandler { req in
            switch (req.method, req.path) {
            case ("GET", "/api/v2/ingest/stream"): return .failure(.timedOut) // probe inconclusive
            case ("PUT", "/api/v2/ingest/stream"): return Response(status: 405)
            case ("POST", "/api/v2/ingest/upload"): return .json(Self.success)
            default: return Response(status: 500)
            }
        }
        let result = try await makeClient().uploadFile(item: item, sourceId: "mac_test")
        XCTAssertFalse(result.usedStreamEndpoint)
    }
    
    func testChecksumMismatchAndServerDetailAreSurfaced() async {
        let (item, _) = makeUploadItem("a.txt")
        StubURLProtocol.setHandler { req in
            if req.method == "GET" { return Response(status: 405) }
            return .json(["detail": "SHA-256 mismatch: client=x, computed=y"], status: 400)
        }
        do {
            _ = try await makeClient().uploadFile(item: item, sourceId: "mac_test")
            XCTFail("expected failure")
        } catch let error as NASClientError {
            XCTAssertTrue(error.isChecksumMismatch)
            XCTAssertTrue(error.localizedDescription.contains("SHA-256 mismatch"))
            XCTAssertFalse(NASClient.isTransient(error))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
    
    /// A 401 is an auth problem: never a reason to fall back to multipart or to remember the stream
    /// route as unsupported.
    func testUnauthorizedUploadNeverFallsBack() async {
        let (item, _) = makeUploadItem("secret.bin")
        StubURLProtocol.setHandler { _ in .json(["detail": "unauthorized"], status: 401) }
        let client = makeClient(token: "wrong")
        for _ in 0..<2 {
            do {
                _ = try await client.uploadFile(item: item, sourceId: "mac_test")
                XCTFail("expected 401")
            } catch {
                XCTAssertEqual(error as? NASClientError, .unauthorized)
                XCTAssertTrue(error.localizedDescription.contains("API token missing or wrong"))
            }
        }
        let recorded = StubURLProtocol.recorded
        XCTAssertFalse(recorded.contains { $0.path == "/api/v2/ingest/upload" })
        XCTAssertEqual(recorded.filter { $0.method == "GET" && $0.path == "/api/v2/ingest/stream" }.count, 2, "a 401 probe is not memoized")
    }
    
    func testPreCheckSendsEachPathOnce() async throws {
        StubURLProtocol.setHandler { req in
            let files = (req.json?["files"] as? [[String: Any]]) ?? []
            return .json(["results": files.map { ["original_path": $0["original_path"] as! String, "status": "need_upload"] }])
        }
        let item = SynapsFileItem(id: "/x/a", originalPath: "/x/a", filename: "a", fileSize: 1, sourceLocation: "T",
                                  modifiedAt: Date(), sha256: String(repeating: "a", count: 64))
        let response = try await makeClient().batchPreCheck(sourceId: "mac_test", friendlyName: "T", platform: "macOS", items: [item, item, item])
        XCTAssertEqual(((StubURLProtocol.recorded.first?.json?["files"]) as? [Any])?.count, 1)
        XCTAssertEqual(response.results.count, 1)
    }
    
    func testUploadWithoutHashIsRejectedLocally() async {
        var (item, _) = makeUploadItem("b.txt")
        item.sha256 = nil
        do {
            _ = try await makeClient().uploadFile(item: item, sourceId: "mac_test")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? NASClientError, .missingChecksum)
        }
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty, "an empty client_sha256 is a guaranteed 400; don't send it")
    }
    
    // MARK: Check / browse / albums / download
    
    func testPreCheckIsSentInBatchesOfAtMost200() async throws {
        StubURLProtocol.setHandler { req in
            let files = (req.json?["files"] as? [[String: Any]]) ?? []
            let results: [[String: Any]] = files.enumerated().map { i, f in
                ["original_path": f["original_path"] as! String, "status": i % 2 == 0 ? "dedup_linked" : "need_upload", "physical_object_id": i % 2 == 0 ? 7 : NSNull()]
            }
            return .json(["source_id": "mac_test", "total_checked": files.count, "results": results])
        }
        let items = (0..<450).map {
            SynapsFileItem(id: "/x/f\($0)", originalPath: "/x/f\($0)", filename: "f\($0)", fileSize: 1, sourceLocation: "T", modifiedAt: Date(), sha256: String(format: "%064d", $0))
        }
        let response = try await makeClient().batchPreCheck(sourceId: "mac_test", friendlyName: "T", platform: "macOS", items: items)
        
        let batches = StubURLProtocol.recorded.map { (($0.json?["files"] as? [Any]) ?? []).count }
        XCTAssertEqual(batches, [200, 200, 50])
        XCTAssertEqual(response.results.count, 450)
        XCTAssertEqual(response.dedupCount, 225)
        XCTAssertEqual(response.results.first?.physical_object_id, "7", "integer ids must not fail the whole decode")
        let firstFile = (StubURLProtocol.recorded.first?.json?["files"] as? [[String: Any]])?.first
        XCTAssertTrue((firstFile?["source_modified_at"] as? String)?.hasSuffix("+00:00") ?? false)
    }
    
    func testMatchExistingBatchesAndDecodesMatches() async throws {
        StubURLProtocol.setHandler { req in
            XCTAssertEqual(req.url.path, "/api/v2/ingest/match")
            let files = (req.json?["files"] as? [[String: Any]]) ?? []
            // the NAS "has" every file whose name ends in 0
            let matches: [[String: Any]] = files.compactMap { f in
                let name = f["filename"] as! String
                return name.hasSuffix("0") ? ["filename": name, "size": f["size"] as! Int, "sha256": "sha-\(name)"] : nil
            }
            return .json(["matches": matches])
        }
        let files = (0..<2500).map { IngestMatchFile(filename: "IMG_\($0)", size: Int64(1000 + $0)) }
        let matches = try await makeClient().matchExisting(files)
        
        let batches = StubURLProtocol.recorded.map { (($0.json?["files"] as? [Any]) ?? []).count }
        XCTAssertEqual(batches, [2000, 500])
        XCTAssertEqual(matches.count, 250)
        XCTAssertEqual(matches.first?.sha256, "sha-IMG_0")
        XCTAssertEqual(matches.first?.size, 1000)
    }
    
    func testBrowseAllPagesReusesTheFirstPage() async throws {
        func page(_ n: Int) -> [String: Any] {
            let count = n < 3 ? 1000 : 500
            let files: [[String: Any]] = (0..<count).map { ["name": "p\(n)-\($0).jpg", "path": "D/p\(n)-\($0).jpg", "type": "file", "size": 1, "modified": "2026-10-13T14:59:00"] }
            return ["current_path": "D", "folders": [], "files": files, "total_folders": 0, "total_files": 2500, "page": n, "per_page": 1000]
        }
        StubURLProtocol.setHandler { req in .json(page(Int(req.query["page"] ?? "1") ?? 1)) }
        let client = makeClient()
        let first = try await client.browseDirectory(path: "D", page: 1, perPage: 1000)
        let all = try await client.browseAllDirectoryFiles(path: "D", firstPage: first)
        XCTAssertEqual(all.count, 2500)
        XCTAssertEqual(StubURLProtocol.recorded.compactMap { $0.query["page"] }, ["1", "2", "3"], "page 1 must not be fetched twice")
    }
    
    func testAlbumSyncUsesAlbumsEndpointAndSurfacesErrors() async throws {
        StubURLProtocol.setHandler { _ in .json(["album_id": "a1", "album_name": "Trip", "newly_linked_items": 2]) }
        try await makeClient().syncAlbums(sourceId: "mac_test", albumName: "Trip", originalPaths: ["/p/1", "/p/2"])
        let req = try XCTUnwrap(StubURLProtocol.recorded.last)
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/api/v2/ingest/albums")
        XCTAssertEqual(req.json?["source_id"] as? String, "mac_test")
        XCTAssertEqual(req.json?["album_name"] as? String, "Trip")
        XCTAssertEqual(req.json?["original_paths"] as? [String], ["/p/1", "/p/2"])
        
        StubURLProtocol.setHandler { _ in .json(["detail": "Source not found"], status: 404) }
        do {
            try await makeClient().syncAlbums(sourceId: "nope", albumName: "Trip", originalPaths: [])
            XCTFail("a 404 must not be swallowed")
        } catch {
            XCTAssertEqual(error as? NASClientError, .httpStatus(404, "Source not found"))
        }
    }
    
    func testDownloadNeverOverwritesAnExistingFile() async throws {
        let dir = TestEnvironment.makeTempDir("downloads")
        let existing = TestEnvironment.writeFile(dir.appendingPathComponent("report.pdf"), Data("mine".utf8))
        StubURLProtocol.setHandler { _ in Response(status: 200, headers: ["Content-Type": "application/pdf"], body: Data("from nas".utf8)) }
        
        let saved = try await makeClient().downloadFile(relativePath: "Vault/report.pdf", destinationURL: existing)
        XCTAssertEqual(saved.lastPathComponent, "report (1).pdf")
        XCTAssertEqual(try Data(contentsOf: existing), Data("mine".utf8))
        XCTAssertEqual(try Data(contentsOf: saved), Data("from nas".utf8))
    }
    
    func testTransientClassification() {
        XCTAssertTrue(NASClient.isTransient(URLError(.timedOut)))
        XCTAssertTrue(NASClient.isTransient(URLError(.networkConnectionLost)))
        XCTAssertTrue(NASClient.isTransient(NASClientError.httpStatus(503, nil)))
        XCTAssertFalse(NASClient.isTransient(NASClientError.httpStatus(500, nil)))
        XCTAssertFalse(NASClient.isTransient(NASClientError.httpStatus(400, nil)))
        XCTAssertFalse(NASClient.isTransient(NASClientError.unauthorized))
        XCTAssertFalse(NASClient.isTransient(URLError(.cancelled)))
        XCTAssertTrue(NASClient.isCancellation(CancellationError()))
    }
}
