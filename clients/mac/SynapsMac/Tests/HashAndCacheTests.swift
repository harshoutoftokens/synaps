import Foundation
import CryptoKit
import XCTest
@testable import SynapsMac

final class HashEngineTests: SynapsTestCase {
    private func hex(_ data: Data) -> String {
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    func testStreamingDigestMatchesOneShotAcrossChunkBoundaries() {
        var bytes = [UInt8](repeating: 0, count: 9 * 1024 * 1024 + 123)
        for i in bytes.indices {
            bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7)
        }
        let data = Data(bytes)
        let url = TestEnvironment.writeFile(TestEnvironment.makeTempDir().appendingPathComponent("big.bin"), data)
        XCTAssertEqual(HashEngine.computeSHA256(for: url.path), hex(data))
        XCTAssertEqual(HashEngine.computeSHA256(for: url.path, chunkSize: 1000), hex(data))
    }
    
    func testEmptyMissingAndDirectory() {
        let dir = TestEnvironment.makeTempDir()
        let empty = TestEnvironment.writeFile(dir.appendingPathComponent("empty"), Data())
        XCTAssertEqual(HashEngine.computeSHA256(for: empty.path), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertNil(HashEngine.computeSHA256(for: dir.appendingPathComponent("missing").path))
        XCTAssertNil(HashEngine.computeSHA256(for: dir.path), "a folder is not hashable content")
    }
    
    func testShouldContinueAbortsHashing() {
        let url = TestEnvironment.writeFile(TestEnvironment.makeTempDir().appendingPathComponent("f"), Data(repeating: 1, count: 10_000))
        XCTAssertNil(HashEngine.computeSHA256(for: url.path, chunkSize: 100, shouldContinue: { false }))
    }
    
    func testParallelHashingCoversEveryFile() async {
        let dir = TestEnvironment.makeTempDir()
        var expected: [String: String] = [:]
        for i in 0..<12 {
            let data = Data("file-\(i)-".utf8) + Data(repeating: UInt8(i), count: i * 1000)
            let url = TestEnvironment.writeFile(dir.appendingPathComponent("f\(i)"), data)
            expected[url.path] = hex(data)
        }
        let result = await HashEngine.computeSHA256s(for: Array(expected.keys), maxConcurrent: 3)
        XCTAssertEqual(result, expected)
    }
}

final class LocalCacheStoreTests: SynapsTestCase {
    private func record(
        _ path: String,
        size: Int64,
        mtime: Double,
        sha: String?,
        synced: Double?,
        status: SyncStatus
    ) -> LocalCacheStore.CachedRecord {
        return LocalCacheStore.CachedRecord(
            path: path, inode: 0, size: size, mtime: mtime, sha256: sha,
            lastSyncedAt: synced, syncStatus: status.rawValue, album: nil, isFavorite: false
        )
    }
    
    func testEditedFileLosesCommittedStatus() {
        let store = TestEnvironment.makeCacheStore()
        let path = "/nonexistent-synaps-test/docs/report.pdf"
        store.saveRecord(record(path, size: 100, mtime: 1000, sha: "aaa", synced: 2000, status: .committed))
        
        // Background hashing saw new content and reports it as uncommitted
        store.saveRecord(record(path, size: 120, mtime: 3000, sha: "bbb", synced: nil, status: .uncommitted))
        
        let r = store.getRecord(for: path)
        XCTAssertEqual(r?.syncStatus, SyncStatus.uncommitted.rawValue)
        XCTAssertNil(r?.lastSyncedAt, "a stale last_synced_at made the scanner show edited files as committed")
        XCTAssertEqual(r?.sha256, "bbb")
        XCTAssertEqual(r?.isCommitted(size: 120, mtime: 3000), false)
    }
    
    func testSameContentStaysCommitted() {
        let store = TestEnvironment.makeCacheStore()
        let path = "/nonexistent-synaps-test/docs/photo.jpg"
        store.saveRecord(record(path, size: 100, mtime: 1000, sha: "aaa", synced: 2000, status: .committed))
        store.saveRecord(record(path, size: 100, mtime: 1000.2, sha: nil, synced: nil, status: .uncommitted))
        
        let r = store.getRecord(for: path)
        XCTAssertEqual(r?.syncStatus, SyncStatus.committed.rawValue)
        XCTAssertEqual(r?.sha256, "aaa")
        XCTAssertEqual(r?.lastSyncedAt, 2000)
    }
    
    /// A reconciliation answer that predates a sync's commit must not revert it.
    func testStaleReconcileDoesNotRevertNewerCommit() {
        let store = TestEnvironment.makeCacheStore()
        let path = "/nonexistent-synaps-test/race/video.mov"
        let reconcileStarted = Date()
        store.recordItemSynced(path: path, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 5), sha256: "abc")
        
        store.updateSyncStatuses(paths: [path], status: .uncommitted, notSyncedSince: reconcileStarted)
        XCTAssertEqual(store.getRecord(for: path)?.syncStatus, SyncStatus.committed.rawValue)
        
        store.updateSyncStatuses(paths: [path], status: .uncommitted, notSyncedSince: Date().addingTimeInterval(60))
        XCTAssertEqual(store.getRecord(for: path)?.syncStatus, SyncStatus.uncommitted.rawValue)
    }
    
    func testVirtualKeysAndUnusualCharactersRoundTrip() {
        let store = TestEnvironment.makeCacheStore()
        let keys = ["iPhone://105APPLE/IMG_0001.HEIC", "/nonexistent-synaps-test/Mixed 'quotes' \"and\" émoji 📸.mov"]
        for key in keys {
            store.saveRecord(record(key, size: 5, mtime: 1, sha: "s", synced: 1, status: .committed))
            XCTAssertEqual(store.getRecord(for: key)?.path, key)
        }
    }
    
    func testRecordsUnderFolderIsAPrefixRange() {
        let store = TestEnvironment.makeCacheStore()
        for p in ["/nonexistent-synaps-test/a/b/c.txt", "/nonexistent-synaps-test/a/b/d/e.txt",
                  "/nonexistent-synaps-test/a/bc/x.txt", "/nonexistent-synaps-test/a/b"] {
            store.saveRecord(record(p, size: 1, mtime: 1, sha: nil, synced: 1, status: .committed))
        }
        let under = store.records(under: "/nonexistent-synaps-test/a/b")
        XCTAssertEqual(Set(under.keys), ["/nonexistent-synaps-test/a/b/c.txt", "/nonexistent-synaps-test/a/b/d/e.txt"])
    }
    
    func testBatchWritesAndActivityLog() {
        let store = TestEnvironment.makeCacheStore()
        let items = (0..<3).map {
            SynapsFileItem(id: "/nonexistent-synaps-test/f\($0)", originalPath: "/nonexistent-synaps-test/f\($0)",
                           filename: "f\($0)", fileSize: 10, sourceLocation: "T", modifiedAt: Date(timeIntervalSince1970: 50), sha256: "h\($0)")
        }
        store.recordItemsSynced(items)
        XCTAssertTrue(items.allSatisfy { store.getRecord(for: $0.originalPath)?.syncStatus == SyncStatus.committed.rawValue })
        
        store.updateSyncStatuses(paths: [items[0].originalPath], status: .uncommitted)
        XCTAssertEqual(store.getRecord(for: items[0].originalPath)?.syncStatus, SyncStatus.uncommitted.rawValue)
        XCTAssertNil(store.getRecord(for: items[0].originalPath)?.lastSyncedAt)
        
        store.logActivities(items.map { SyncActivityItem(eventType: .fileSynced, filePath: $0.originalPath, details: "ok") })
        XCTAssertEqual(store.getRecentActivity(limit: 10).count, 3)
    }
}

final class LocalFileScannerTests: SynapsTestCase {
    func testEditedFileIsReportedUncommittedAfterRehash() throws {
        let store = TestEnvironment.makeCacheStore()
        let scanner = LocalFileScanner(cacheStore: store)
        let dir = TestEnvironment.makeTempDir("scan")
        let file = TestEnvironment.writeFile(dir.appendingPathComponent("notes.txt"), Data("version one".utf8))
        
        // Pretend the first version was committed
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        store.saveRecord(LocalCacheStore.CachedRecord(
            path: file.path, inode: 0, size: (attrs[.size] as! NSNumber).int64Value,
            mtime: (attrs[.modificationDate] as! Date).timeIntervalSince1970,
            sha256: "0000", lastSyncedAt: 1, syncStatus: SyncStatus.committed.rawValue, album: nil, isFavorite: false
        ))
        
        // Edit it (new size and mtime)
        try Data("version two, longer".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        
        let hashed = expectation(description: "hashed")
        var reported: [SynapsFileItem] = []
        scanner.onItemsHashed = { items in
            reported.append(contentsOf: items)
            hashed.fulfill()
        }
        
        let scanExpectation = expectation(description: "scanned")
        var listed: [SynapsFileItem] = []
        Task {
            listed = await scanner.scanDirectory(directoryPath: dir.path, sourceLocation: "Tests")
            scanExpectation.fulfill()
        }
        wait(for: [scanExpectation, hashed], timeout: 10)
        
        XCTAssertEqual(listed.first?.syncStatus, .uncommitted)
        XCTAssertEqual(reported.first?.syncStatus, .uncommitted, "edited content must not inherit the old committed status")
        XCTAssertNotNil(reported.first?.sha256)
        let saved = store.getRecord(for: file.path)
        XCTAssertEqual(saved?.syncStatus, SyncStatus.uncommitted.rawValue)
        XCTAssertNil(saved?.lastSyncedAt)
    }
    
    func testFolderStatusSkipsIgnoredDirectories() throws {
        let store = TestEnvironment.makeCacheStore()
        let scanner = LocalFileScanner(cacheStore: store)
        let dir = TestEnvironment.makeTempDir("project")
        let committedFile = TestEnvironment.writeFile(dir.appendingPathComponent("src/main.c"), Data("int main(){}".utf8))
        TestEnvironment.writeFile(dir.appendingPathComponent("node_modules/pkg/index.js"), Data("x".utf8))
        TestEnvironment.writeFile(dir.appendingPathComponent("venv/lib/site.py"), Data("y".utf8))
        
        let item = TestEnvironment.fileItem(for: committedFile)
        store.recordItemSynced(path: item.originalPath, fileSize: item.fileSize, modifiedAt: item.modifiedAt, sha256: nil)
        
        XCTAssertEqual(scanner.evaluateFolderSyncStatus(folderPath: dir.path), .committed)
        
        let files = scanner.scanDirectoryRecursively(directoryPath: dir.path, sourceLocation: "Tests")
        XCTAssertEqual(files.map { $0.filename }, ["main.c"], "node_modules/venv contents must not be synced")
        XCTAssertEqual(files.first?.syncStatus, .committed)
    }
    
    func testFolderStatusFlagsUncommittedFile() {
        let store = TestEnvironment.makeCacheStore()
        let scanner = LocalFileScanner(cacheStore: store)
        let dir = TestEnvironment.makeTempDir("mixed")
        for i in 0..<70 {
            let url = TestEnvironment.writeFile(dir.appendingPathComponent("f\(i).txt"), Data("\(i)".utf8))
            let item = TestEnvironment.fileItem(for: url)
            store.recordItemSynced(path: item.originalPath, fileSize: item.fileSize, modifiedAt: item.modifiedAt, sha256: nil)
        }
        XCTAssertEqual(scanner.evaluateFolderSyncStatus(folderPath: dir.path), .committed)
        TestEnvironment.writeFile(dir.appendingPathComponent("zz-new.txt"), Data("new".utf8))
        XCTAssertEqual(scanner.evaluateFolderSyncStatus(folderPath: dir.path), .uncommitted)
    }
}
