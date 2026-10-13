import Foundation
import XCTest
@testable import SynapsMac

final class NASReconciliationTests: SynapsTestCase {
    
    // MARK: - IngestCheckBatchResponse decoding (backend & legacy format)
    
    func testDecodesLiveBackendCheckResponse() throws {
        // Exact JSON returned by the NAS backend /api/v2/ingest/check
        let json = """
        {
            "source_id": "mac_harsh",
            "total_checked": 2,
            "need_upload": 1,
            "dedup_linked": 1,
            "results": [
                {
                    "original_path": "/Users/harshrathod/Downloads/01_Netflix_Logo (1).zip",
                    "status": "dedup_linked",
                    "physical_object_id": "a2a4413d-ff1b-40a4-a82b-469a7d7fbfc8"
                },
                {
                    "original_path": "/Users/harshrathod/Downloads/NewFile.zip",
                    "status": "need_upload",
                    "physical_object_id": null
                }
            ]
        }
        """
        let decoded = try JSONDecoder().decode(IngestCheckBatchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.source_id, "mac_harsh")
        XCTAssertEqual(decoded.total_checked, 2)
        XCTAssertEqual(decoded.dedupCount, 1)
        XCTAssertEqual(decoded.needUploadCount, 1)
        XCTAssertEqual(decoded.results.count, 2)
        XCTAssertEqual(decoded.results[0].status, "dedup_linked")
        XCTAssertEqual(decoded.results[0].physical_object_id, "a2a4413d-ff1b-40a4-a82b-469a7d7fbfc8")
        XCTAssertNil(decoded.results[1].physical_object_id)
    }
    
    func testDecodesLegacyCheckResponse() throws {
        let json = """
        {"status": "success", "total_checked": 1, "dedup_count": 1, "need_upload_count": 0,
         "results": [{"original_path": "/Users/harshrathod/Downloads/file.pdf", "status": "dedup_linked"}]}
        """
        let decoded = try JSONDecoder().decode(IngestCheckBatchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, "success")
        XCTAssertEqual(decoded.dedupCount, 1)
        XCTAssertEqual(decoded.needUploadCount, 0)
    }
    
    // MARK: - Mirror path resolution
    
    func testMirrorPathResolution() {
        XCTAssertEqual(NASReconciliationEngine.resolveMirrorPath(for: "/Users/harshrathod/Downloads"), "Mirrors/Harsh/Mac/Downloads")
        XCTAssertEqual(NASReconciliationEngine.resolveMirrorPath(for: "/Users/harshrathod/Downloads/01_Netflix_Logo"), "Mirrors/Harsh/Mac/Downloads/01_Netflix_Logo")
        XCTAssertEqual(NASReconciliationEngine.resolveMirrorPath(for: "/Users/harshrathod/Desktop"), "Mirrors/Harsh/Mac/Desktop")
        XCTAssertEqual(NASReconciliationEngine.resolveMirrorPath(for: "/Users/harshrathod/Desktop/DAA/Labs"), "Mirrors/Harsh/Mac/Desktop/DAA/Labs")
        XCTAssertEqual(NASReconciliationEngine.resolveMirrorPath(for: "Downloads", sourceLocation: "Downloads"), "Mirrors/Harsh/Mac/Downloads")
    }
    
    // MARK: - Fast tier, deep tier and stale-cache invalidation against a stubbed NAS
    
    private func item(_ name: String, size: Int64, sha: String? = nil, status: SyncStatus = .uncommitted) -> SynapsFileItem {
        let path = "/Users/harshrathod/Downloads/\(name)"
        return SynapsFileItem(id: path, originalPath: path, filename: name, fileSize: size, sourceLocation: "Downloads",
                              modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), sha256: sha, syncStatus: status)
    }
    
    func testReconcileDirectory() async {
        let store = TestEnvironment.makeCacheStore()
        let mirrorFiles: [[String: Any]] = [
            ["name": "IMG_8436.MOV", "path": "Mirrors/Harsh/Mac/Downloads/IMG_8436.MOV", "type": "file", "size": 170005440],
            ["name": "report.pdf", "path": "Mirrors/Harsh/Mac/Downloads/report.pdf", "type": "file", "size": 1048576],
            ["name": "modified.txt", "path": "Mirrors/Harsh/Mac/Downloads/modified.txt", "type": "file", "size": 150]
        ]
        StubURLProtocol.setHandler { req in
            switch req.path {
            case "/api/finder/browse":
                XCTAssertEqual(req.query["path"], "Mirrors/Harsh/Mac/Downloads")
                return .json(["current_path": "Mirrors/Harsh/Mac/Downloads", "folders": [], "files": mirrorFiles,
                              "total_folders": 0, "total_files": mirrorFiles.count, "page": 1, "per_page": 1000])
            case "/api/v2/ingest/check":
                let files = (req.json?["files"] as? [[String: Any]]) ?? []
                let results = files.map { f -> [String: Any] in
                    let path = f["original_path"] as! String
                    let known = (f["client_sha256"] as? String) == "sha_iphone_synced_photo"
                    return ["original_path": path, "status": known ? "dedup_linked" : "need_upload"]
                }
                return .json(["source_id": "mac_harsh", "results": results])
            default:
                return Response(status: 404)
            }
        }
        
        let local = [
            item("IMG_8436.MOV", size: 170005440),                                      // same name+size in mirror
            item("report.pdf", size: 1048576),
            item("modified.txt", size: 200),                                            // size differs
            item("brand_new.png", size: 50000),                                         // not on NAS, no hash
            item("renamed_photo.jpg", size: 3000, sha: "sha_iphone_synced_photo"),      // in vault under another name
            item("unseen_file.zip", size: 9000, sha: "sha_unknown"),
            item("deleted_on_nas.pdf", size: 4096, status: .committed)                  // stale local "committed"
        ]
        let engine = NASReconciliationEngine(nasClient: makeClient(), cacheStore: store)
        let result = await engine.reconcileDirectory(
            directoryPath: "/Users/harshrathod/Downloads",
            sourceLocation: "Downloads",
            localItems: local
        )
        let status = Dictionary(uniqueKeysWithValues: result.map { ($0.filename, $0.syncStatus) })
        XCTAssertEqual(status["IMG_8436.MOV"], .committed)
        XCTAssertEqual(status["report.pdf"], .committed)
        XCTAssertEqual(status["modified.txt"], .uncommitted)
        XCTAssertEqual(status["brand_new.png"], .uncommitted)
        XCTAssertEqual(status["renamed_photo.jpg"], .committed, "cross-device content matched by SHA-256")
        XCTAssertEqual(status["unseen_file.zip"], .uncommitted)
        XCTAssertEqual(status["deleted_on_nas.pdf"], .uncommitted, "stale committed state is invalidated")
        
        XCTAssertEqual(store.getRecord(for: "/Users/harshrathod/Downloads/report.pdf")?.syncStatus, SyncStatus.committed.rawValue)
        XCTAssertEqual(store.getRecord(for: "/Users/harshrathod/Downloads/renamed_photo.jpg")?.syncStatus, SyncStatus.committed.rawValue)
        let checkRequests = StubURLProtocol.recorded.filter { $0.path == "/api/v2/ingest/check" }
        XCTAssertEqual(checkRequests.count, 1, "only hashed, unmatched files go to the deep tier")
    }
    
    func testNetworkFailureLeavesStatusesUntouched() async {
        StubURLProtocol.setHandler { _ in .failure(.cannotConnectToHost) }
        let local = [item("a.txt", size: 1, status: .committed), item("b.txt", size: 2)]
        let result = await NASReconciliationEngine(nasClient: makeClient(), cacheStore: TestEnvironment.makeCacheStore())
            .reconcileDirectory(directoryPath: "/Users/harshrathod/Downloads", sourceLocation: "Downloads", localItems: local)
        XCTAssertEqual(result.map { $0.syncStatus }, [.committed, .uncommitted])
    }
}
