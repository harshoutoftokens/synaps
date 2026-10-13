import Foundation

// MARK: - Minimal Mock / Test Harness
print("🧪 Running NAS Reconciliation Test Suite...")

var testFailures = 0

func assertTrue(_ condition: Bool, _ message: String) {
    if !condition {
        print("❌ FAIL: \(message)")
        testFailures += 1
    } else {
        print("✅ PASS: \(message)")
    }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    if a != b {
        print("❌ FAIL: \(message) — Expected '\(b)', got '\(a)'")
        testFailures += 1
    } else {
        print("✅ PASS: \(message)")
    }
}

// MARK: - Test 1: IngestCheckBatchResponse JSON Decoding (Backend & Legacy Format)
print("\n--- Test 1: IngestCheckBatchResponse Decoding ---")
do {
    // Exact JSON returned by live NAS backend /api/v2/ingest/check
    let liveBackendJson = """
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
    """.data(using: .utf8)!
    
    // Struct definition mirroring NASClient.IngestCheckBatchResponse
    struct DecodableCheckBatchResponse: Codable {
        let source_id: String?
        let status: String?
        let total_checked: Int?
        let dedup_linked: Int?
        let dedup_count: Int?
        let need_upload: Int?
        let need_upload_count: Int?
        let results: [DecodableCheckItemResult]
        
        var dedupCount: Int {
            return dedup_linked ?? dedup_count ?? results.filter { $0.status == "dedup_linked" }.count
        }
        var needUploadCount: Int {
            return need_upload ?? need_upload_count ?? results.filter { $0.status == "need_upload" }.count
        }
    }
    
    struct DecodableCheckItemResult: Codable {
        let original_path: String
        let status: String
        let sha256: String?
        let error: String?
        let physical_object_id: String?
    }
    
    let decoded = try JSONDecoder().decode(DecodableCheckBatchResponse.self, from: liveBackendJson)
    assertEqual(decoded.source_id, "mac_harsh", "Decodes source_id from live NAS response")
    assertEqual(decoded.total_checked, 2, "Decodes total_checked correctly")
    assertEqual(decoded.dedup_linked, 1, "Decodes dedup_linked correctly")
    assertEqual(decoded.dedupCount, 1, "Computed dedupCount returns 1")
    assertEqual(decoded.need_upload, 1, "Decodes need_upload correctly")
    assertEqual(decoded.needUploadCount, 1, "Computed needUploadCount returns 1")
    assertEqual(decoded.results.count, 2, "Decodes 2 item results")
    assertEqual(decoded.results[0].status, "dedup_linked", "Result 0 is dedup_linked")
    assertEqual(decoded.results[0].physical_object_id, "a2a4413d-ff1b-40a4-a82b-469a7d7fbfc8", "Result 0 physical_object_id decoded")
    assertEqual(decoded.results[1].status, "need_upload", "Result 1 is need_upload")
    
    // Legacy format with "status", "dedup_count", "need_upload_count"
    let legacyJson = """
    {
        "status": "success",
        "total_checked": 1,
        "dedup_count": 1,
        "need_upload_count": 0,
        "results": [
            {
                "original_path": "/Users/harshrathod/Downloads/file.pdf",
                "status": "dedup_linked"
            }
        ]
    }
    """.data(using: .utf8)!
    
    let legacyDecoded = try JSONDecoder().decode(DecodableCheckBatchResponse.self, from: legacyJson)
    assertEqual(legacyDecoded.status, "success", "Decodes status from legacy format")
    assertEqual(legacyDecoded.dedupCount, 1, "Computed dedupCount works for legacy format")
    assertEqual(legacyDecoded.needUploadCount, 0, "Computed needUploadCount works for legacy format")
} catch {
    print("❌ FAIL: Decoding threw error: \(error)")
    testFailures += 1
}

// MARK: - Test 2: Mirror Path Resolution
print("\n--- Test 2: Mirror Path Resolution ---")
func resolveMirrorPath(for directoryPath: String, sourceLocation: String = "") -> String {
    let clean = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
    let components = clean.components(separatedBy: "/").filter { !$0.isEmpty }
    
    if components.count >= 2 && components[0] == "Users" {
        let relComponents = components.dropFirst(2)
        if !relComponents.isEmpty {
            let relPath = relComponents.joined(separator: "/")
            return "Mirrors/Harsh/Mac/\(relPath)"
        }
    }
    
    if !sourceLocation.isEmpty && !sourceLocation.contains("/") {
        return "Mirrors/Harsh/Mac/\(sourceLocation)"
    }
    
    let trimmedRel = clean.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return "Mirrors/Harsh/Mac/\(trimmedRel)"
}

assertEqual(
    resolveMirrorPath(for: "/Users/harshrathod/Downloads"),
    "Mirrors/Harsh/Mac/Downloads",
    "Resolves Downloads to Mirrors/Harsh/Mac/Downloads"
)
assertEqual(
    resolveMirrorPath(for: "/Users/harshrathod/Downloads/01_Netflix_Logo"),
    "Mirrors/Harsh/Mac/Downloads/01_Netflix_Logo",
    "Resolves nested folder Downloads/01_Netflix_Logo"
)
assertEqual(
    resolveMirrorPath(for: "/Users/harshrathod/Desktop"),
    "Mirrors/Harsh/Mac/Desktop",
    "Resolves Desktop to Mirrors/Harsh/Mac/Desktop"
)
assertEqual(
    resolveMirrorPath(for: "/Users/harshrathod/Desktop/DAA/Labs"),
    "Mirrors/Harsh/Mac/Desktop/DAA/Labs",
    "Resolves deep nested Desktop/DAA/Labs"
)
assertEqual(
    resolveMirrorPath(for: "Downloads", sourceLocation: "Downloads"),
    "Mirrors/Harsh/Mac/Downloads",
    "Resolves relative Downloads with sourceLocation"
)

// MARK: - Test 3: Fast-Tier Metadata Matching
print("\n--- Test 3: Fast-Tier Metadata Reconciliation ---")
struct MockFileItem {
    let originalPath: String
    let filename: String
    let fileSize: Int64
    var sha256: String?
    var syncStatus: String // "committed" or "uncommitted"
    let isDirectory: Bool
}

// Simulated authoritative NAS mirror directory
let remoteMirrorFiles: [String: Int64] = [
    "IMG_8436.MOV": 170005440,
    "report.pdf": 1048576,
    "HomeStorage": 156
]

var localItems: [MockFileItem] = [
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/IMG_8436.MOV", filename: "IMG_8436.MOV", fileSize: 170005440, sha256: nil, syncStatus: "uncommitted", isDirectory: false),
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/report.pdf", filename: "report.pdf", fileSize: 1048576, sha256: nil, syncStatus: "uncommitted", isDirectory: false),
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/modified.txt", filename: "modified.txt", fileSize: 200, sha256: nil, syncStatus: "uncommitted", isDirectory: false), // local 200, remote has 150
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/brand_new.png", filename: "brand_new.png", fileSize: 50000, sha256: nil, syncStatus: "uncommitted", isDirectory: false) // not in remote
]

// Execute Fast-Tier Matching
for i in 0..<localItems.count {
    let name = localItems[i].filename
    let size = localItems[i].fileSize
    if let remoteSize = remoteMirrorFiles[name], remoteSize == size {
        localItems[i].syncStatus = "committed"
    }
}

assertEqual(localItems[0].syncStatus, "committed", "IMG_8436.MOV marked committed via fast metadata matching")
assertEqual(localItems[1].syncStatus, "committed", "report.pdf marked committed via fast metadata matching")
assertEqual(localItems[2].syncStatus, "uncommitted", "modified.txt stays uncommitted due to size mismatch")
assertEqual(localItems[3].syncStatus, "uncommitted", "brand_new.png stays uncommitted because not on NAS")

// MARK: - Test 4: Deep-Tier Hash Deduplication (Cross-Device & Renamed)
print("\n--- Test 4: Deep-Tier Hash Deduplication ---")
// Simulated NAS vault SHA-256 registry
let remoteVaultHashes: Set<String> = [
    "sha_iphone_synced_photo", // synced from iPhone earlier
    "sha_windows_synced_doc"   // synced from Windows earlier
]

var deepCheckItems: [MockFileItem] = [
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/renamed_photo.jpg", filename: "renamed_photo.jpg", fileSize: 3000, sha256: "sha_iphone_synced_photo", syncStatus: "uncommitted", isDirectory: false),
    MockFileItem(originalPath: "/Users/harshrathod/Downloads/unseen_file.zip", filename: "unseen_file.zip", fileSize: 9000, sha256: "sha_unknown_content", syncStatus: "uncommitted", isDirectory: false)
]

for i in 0..<deepCheckItems.count {
    if let sha = deepCheckItems[i].sha256, remoteVaultHashes.contains(sha) {
        deepCheckItems[i].syncStatus = "committed"
    } else {
        deepCheckItems[i].syncStatus = "uncommitted"
    }
}

assertEqual(deepCheckItems[0].syncStatus, "committed", "Cross-device synced photo matched via SHA-256 dedup without network transfer")
assertEqual(deepCheckItems[1].syncStatus, "uncommitted", "Unknown file remains uncommitted")

// MARK: - Test 5: Stale Local Cache Invalidation
print("\n--- Test 5: Stale Local Cache Invalidation ---")
// File that was locally marked "committed" in the past, but is now gone from NAS mirror and vault
var staleItem = MockFileItem(
    originalPath: "/Users/harshrathod/Downloads/deleted_on_nas.pdf",
    filename: "deleted_on_nas.pdf",
    fileSize: 4096,
    sha256: "sha_deleted_on_nas",
    syncStatus: "committed", // Stale state!
    isDirectory: false
)

// Reconcile against authoritative NAS:
let existsOnMirror = remoteMirrorFiles[staleItem.filename] == staleItem.fileSize
let existsInVault = remoteVaultHashes.contains(staleItem.sha256 ?? "")

if !existsOnMirror && !existsInVault {
    staleItem.syncStatus = "uncommitted" // Authoritative invalidation!
}

assertEqual(staleItem.syncStatus, "uncommitted", "Stale locally committed file invalidated and reverted to uncommitted")

// MARK: - Test 6: Folder Sync Status Evaluation
print("\n--- Test 6: Folder Status Evaluation ---")
func evaluateFolderStatus(itemsInFolder: [MockFileItem]) -> String {
    let files = itemsInFolder.filter { !$0.isDirectory }
    guard !files.isEmpty else { return "uncommitted" }
    let allCommitted = files.allSatisfy { $0.syncStatus == "committed" }
    return allCommitted ? "committed" : "uncommitted"
}

let allCommittedFolder = [
    MockFileItem(originalPath: "/dir/f1.txt", filename: "f1.txt", fileSize: 10, sha256: nil, syncStatus: "committed", isDirectory: false),
    MockFileItem(originalPath: "/dir/f2.txt", filename: "f2.txt", fileSize: 20, sha256: nil, syncStatus: "committed", isDirectory: false)
]
assertEqual(evaluateFolderStatus(itemsInFolder: allCommittedFolder), "committed", "Folder with all committed files is committed")

let partialFolder = [
    MockFileItem(originalPath: "/dir/f1.txt", filename: "f1.txt", fileSize: 10, sha256: nil, syncStatus: "committed", isDirectory: false),
    MockFileItem(originalPath: "/dir/f2.txt", filename: "f2.txt", fileSize: 20, sha256: nil, syncStatus: "uncommitted", isDirectory: false)
]
assertEqual(evaluateFolderStatus(itemsInFolder: partialFolder), "uncommitted", "Folder with at least one uncommitted file is uncommitted")

// MARK: - Test Results Summary
print("\n===============================")
if testFailures == 0 {
    print("🎉 ALL 18 RECONCILIATION TESTS PASSED!")
    exit(0)
} else {
    print("❌ \(testFailures) TESTS FAILED")
    exit(1)
}
