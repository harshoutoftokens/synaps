import Foundation

// MARK: - Live NAS Integration Test
print("🌐 Running Live NAS Integration Test against http://192.168.0.101:8000...")

var integrationFailures = 0

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ FAIL: \(message)")
        integrationFailures += 1
    } else {
        print("✅ PASS: \(message)")
    }
}

// 1. Test live health check
let healthUrl = URL(string: "http://192.168.0.101:8000/api/health")!
var req = URLRequest(url: healthUrl)
req.timeoutInterval = 3.0

let sema = DispatchSemaphore(value: 0)

URLSession.shared.dataTask(with: req) { data, response, error in
    defer { sema.signal() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data else {
        assertTrue(false, "Live NAS health check reachable")
        return
    }
    if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       json["status"] as? String == "ok" {
        assertTrue(true, "Live NAS health check status ok")
    } else {
        assertTrue(false, "Live NAS health check unexpected payload")
    }
}.resume()

sema.wait()

// 2. Test live browse pagination on Mirrors/Harsh/Mac/Downloads
let browseUrl = URL(string: "http://192.168.0.101:8000/api/finder/browse?path=Mirrors/Harsh/Mac/Downloads&per_page=1000&page=1")!
var browseReq = URLRequest(url: browseUrl)
browseReq.timeoutInterval = 5.0

URLSession.shared.dataTask(with: browseReq) { data, response, error in
    defer { sema.signal() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data else {
        assertTrue(false, "Live NAS browse Downloads reachable")
        return
    }
    if let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
       let totalFiles = json["total_files"] as? Int,
       let files = json["files"] as? [[String: Any]] {
        assertTrue(totalFiles >= 1900, "Live NAS mirrors Downloads contains \(totalFiles) files (expected >= 1900)")
        assertTrue(files.count == 1000, "Page 1 returned exact 1000 files")
    } else {
        assertTrue(false, "Failed to parse browse JSON")
    }
}.resume()

sema.wait()

// 3. Test live ingest/check deduplication API
let checkUrl = URL(string: "http://192.168.0.101:8000/api/v2/ingest/check")!
var checkReq = URLRequest(url: checkUrl)
checkReq.httpMethod = "POST"
checkReq.setValue("application/json", forHTTPHeaderField: "Content-Type")

let payload: [String: Any] = [
    "source": [
        "id": "mac_harsh",
        "friendly_name": "Harsh's Mac",
        "platform": "macOS",
        "volume_identifier": NSNull()
    ],
    "files": [
        [
            "original_path": "/Users/harshrathod/Downloads/01_Netflix_Logo (1).zip",
            "original_filename": "01_Netflix_Logo (1).zip",
            "file_size": 310565,
            "source_location": "Downloads",
            "source_modified_at": "2026-09-30T12:00:00Z",
            "client_sha256": "7c8c0d8e21f673b2a73b02de7ed332d48a3dd91cb02e355e34884a2ac0fd3c7d"
        ]
    ]
]
checkReq.httpBody = try! JSONSerialization.data(withJSONObject: payload)

URLSession.shared.dataTask(with: checkReq) { data, response, error in
    defer { sema.signal() }
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, let d = data else {
        assertTrue(false, "Live NAS /api/v2/ingest/check reachable")
        return
    }
    
    struct IngestCheckBatchResponse: Codable {
        let source_id: String?
        let total_checked: Int?
        let dedup_linked: Int?
        let need_upload: Int?
        let results: [Item]
        struct Item: Codable {
            let original_path: String
            let status: String
            let physical_object_id: String?
        }
    }
    
    do {
        let res = try JSONDecoder().decode(IngestCheckBatchResponse.self, from: d)
        assertTrue(res.source_id == "mac_harsh", "Decodes source_id: mac_harsh")
        assertTrue(res.dedup_linked == 1, "Decodes dedup_linked == 1")
        assertTrue(res.results.first?.status == "dedup_linked", "Identifies existing file as dedup_linked")
        assertTrue(res.results.first?.physical_object_id != nil, "Contains physical_object_id")
    } catch {
        assertTrue(false, "JSONDecoder failed: \(error)")
    }
}.resume()

sema.wait()

print("\n===============================")
if integrationFailures == 0 {
    print("🎉 ALL LIVE NAS INTEGRATION TESTS PASSED!")
    exit(0)
} else {
    print("❌ \(integrationFailures) INTEGRATION TESTS FAILED")
    exit(1)
}
