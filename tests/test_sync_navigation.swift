import Foundation
import SQLite3

// Mock or import models for standalone verification
enum SyncStatus: String {
    case uncommitted = "uncommitted"
    case syncing = "syncing"
    case committed = "committed"
    case failed = "failed"
}

struct CachedRecord {
    let path: String
    let inode: Int64
    let size: Int64
    let mtime: Double
    let sha256: String?
    let lastSyncedAt: Double?
    let syncStatus: String
    let album: String?
    let isFavorite: Bool
}

class TestCacheStore {
    var db: OpaquePointer?
    let dbPath: String
    
    init(dbPath: String, simulateOldSchema: Bool = false) {
        self.dbPath = dbPath
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            fatalError("Could not open db at \(dbPath)")
        }
        
        if simulateOldSchema {
            createOldSchema()
        } else {
            createTables()
            migrateSchema()
        }
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    func createOldSchema() {
        let sql = """
        CREATE TABLE IF NOT EXISTS local_files (
            path TEXT PRIMARY KEY,
            inode INTEGER,
            size INTEGER,
            mtime REAL,
            sha256 TEXT,
            last_synced_at REAL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
    
    func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS local_files (
            path TEXT PRIMARY KEY,
            inode INTEGER,
            size INTEGER,
            mtime REAL,
            sha256 TEXT,
            last_synced_at REAL,
            sync_status TEXT DEFAULT 'uncommitted',
            album TEXT,
            is_favorite INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS ix_mtime ON local_files (mtime);
        CREATE INDEX IF NOT EXISTS ix_sha256 ON local_files (sha256);
        CREATE INDEX IF NOT EXISTS ix_sync_status ON local_files (sync_status);
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }
    
    func migrateSchema() {
        var existingColumns = Set<String>()
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA table_info(local_files);", -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let colName = sqlite3_column_text(stmt, 1) {
                    existingColumns.insert(String(cString: colName).lowercased())
                }
            }
            sqlite3_finalize(stmt)
        }
        
        let migrations: [(col: String, alterSql: String)] = [
            ("sync_status", "ALTER TABLE local_files ADD COLUMN sync_status TEXT DEFAULT 'uncommitted';"),
            ("album", "ALTER TABLE local_files ADD COLUMN album TEXT;"),
            ("is_favorite", "ALTER TABLE local_files ADD COLUMN is_favorite INTEGER DEFAULT 0;")
        ]
        
        for migration in migrations {
            if !existingColumns.contains(migration.col) {
                _ = sqlite3_exec(db, migration.alterSql, nil, nil, nil)
            }
        }
        
        _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS ix_sync_status ON local_files (sync_status);", nil, nil, nil)
    }
    
    static func normalizePath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
    
    func getRecord(for path: String) -> CachedRecord? {
        let norm = Self.normalizePath(path)
        let sql = "SELECT path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite FROM local_files WHERE path = ? OR path = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (norm as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (path as NSString).utf8String, -1, nil)
        if sqlite3_step(stmt) == SQLITE_ROW {
            let p = String(cString: sqlite3_column_text(stmt, 0))
            let inode = sqlite3_column_int64(stmt, 1)
            let size = sqlite3_column_int64(stmt, 2)
            let mtime = sqlite3_column_double(stmt, 3)
            let sha = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
            let syncedAt = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_double(stmt, 5) : nil
            let status = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "uncommitted"
            let album = sqlite3_column_text(stmt, 7).map { String(cString: $0) }
            let isFav = sqlite3_column_int(stmt, 8) != 0
            
            return CachedRecord(
                path: p,
                inode: inode,
                size: size,
                mtime: mtime,
                sha256: sha,
                lastSyncedAt: syncedAt,
                syncStatus: status,
                album: album,
                isFavorite: isFav
            )
        }
        return nil
    }
    
    func saveRecord(_ record: CachedRecord) {
        let norm = Self.normalizePath(record.path)
        let sql = """
        INSERT INTO local_files (path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            inode = excluded.inode,
            size = excluded.size,
            mtime = excluded.mtime,
            sha256 = COALESCE(excluded.sha256, local_files.sha256),
            last_synced_at = COALESCE(excluded.last_synced_at, local_files.last_synced_at),
            sync_status = CASE
                WHEN local_files.sync_status = 'committed' AND excluded.sync_status = 'uncommitted' THEN 'committed'
                ELSE excluded.sync_status
            END,
            album = COALESCE(excluded.album, local_files.album),
            is_favorite = excluded.is_favorite;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        sqlite3_bind_text(stmt, 1, (norm as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 2, record.inode)
        sqlite3_bind_int64(stmt, 3, record.size)
        sqlite3_bind_double(stmt, 4, record.mtime)
        
        if let sha = record.sha256 {
            sqlite3_bind_text(stmt, 5, (sha as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        
        if let syncedAt = record.lastSyncedAt {
            sqlite3_bind_double(stmt, 6, syncedAt)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        
        sqlite3_bind_text(stmt, 7, (record.syncStatus as NSString).utf8String, -1, nil)
        
        if let album = record.album {
            sqlite3_bind_text(stmt, 8, (album as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        
        sqlite3_bind_int(stmt, 9, record.isFavorite ? 1 : 0)
        _ = sqlite3_step(stmt)
    }
    
    func markSynced(paths: [String], status: SyncStatus = .committed) {
        let now = Date().timeIntervalSince1970
        let fileManager = FileManager.default
        let sql = """
        INSERT INTO local_files (path, inode, size, mtime, sha256, last_synced_at, sync_status)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            sync_status = excluded.sync_status,
            last_synced_at = excluded.last_synced_at,
            size = CASE WHEN excluded.size > 0 THEN excluded.size ELSE local_files.size END,
            mtime = CASE WHEN excluded.mtime > 0 THEN excluded.mtime ELSE local_files.mtime END,
            inode = CASE WHEN excluded.inode > 0 THEN excluded.inode ELSE local_files.inode END;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        for path in paths {
            let norm = Self.normalizePath(path)
            let stat = (try? fileManager.attributesOfItem(atPath: norm)) ?? (try? fileManager.attributesOfItem(atPath: path))
            let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
            let size = (stat?[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (stat?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (norm as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 2, inode)
            sqlite3_bind_int64(stmt, 3, size)
            sqlite3_bind_double(stmt, 4, mtime)
            sqlite3_bind_null(stmt, 5)
            sqlite3_bind_double(stmt, 6, now)
            sqlite3_bind_text(stmt, 7, (status.rawValue as NSString).utf8String, -1, nil)
            _ = sqlite3_step(stmt)
        }
    }
}

// Scanner simulation using exact scanner logic
class TestScanner {
    let cacheStore: TestCacheStore
    
    init(cacheStore: TestCacheStore) {
        self.cacheStore = cacheStore
    }
    
    func evaluateFolderSyncStatus(folderPath: String) -> SyncStatus {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: folderPath)
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return .uncommitted
        }
        
        var fileCount = 0
        for case let fileURL as URL in enumerator {
            guard let rv = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]),
                  !(rv.isDirectory ?? false) else {
                continue
            }
            
            fileCount += 1
            let p = fileURL.path
            let size = Int64(rv.fileSize ?? 0)
            let mtime = rv.contentModificationDate ?? Date()
            
            guard let record = self.cacheStore.getRecord(for: p),
                  (record.syncStatus == SyncStatus.committed.rawValue || record.lastSyncedAt != nil),
                  record.size == size,
                  abs(record.mtime - mtime.timeIntervalSince1970) < 1.0 else {
                return .uncommitted
            }
        }
        
        return fileCount > 0 ? .committed : .uncommitted
    }
    
    func scanDirectory(directoryPath: String) -> [String: SyncStatus] {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: directoryPath)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        
        var statuses: [String: SyncStatus] = [:]
        for fileURL in urls {
            let path = fileURL.path
            let filename = fileURL.lastPathComponent
            guard let rv = try? fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else {
                continue
            }
            
            if rv.isDirectory ?? false {
                statuses[filename] = evaluateFolderSyncStatus(folderPath: path)
            } else {
                let size = Int64(rv.fileSize ?? 0)
                let mtime = rv.contentModificationDate ?? Date()
                var syncStatus: SyncStatus = .uncommitted
                
                if let cached = cacheStore.getRecord(for: path) {
                    if cached.size == size && abs(cached.mtime - mtime.timeIntervalSince1970) < 1.0 {
                        if cached.lastSyncedAt != nil || cached.syncStatus == SyncStatus.committed.rawValue {
                            syncStatus = .committed
                        }
                    }
                }
                statuses[filename] = syncStatus
            }
        }
        return statuses
    }
}

// ─────────────────────────────────────────────
// EXECUTE VERIFICATION SUITE
// ─────────────────────────────────────────────

print("🚀 Running Synapse Persistent Sync State & Navigation Verification Suite...")

let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }

let dbFile = tempDir.appendingPathComponent("test_state.db").path

// ── TEST 1: Schema Migration from Old SQLite Database ──
print("\n[TEST 1] Testing Schema Migration on Existing Database...")
let oldStore = TestCacheStore(dbPath: dbFile, simulateOldSchema: true)
// Verify old schema has no sync_status column
var stmt: OpaquePointer?
var cols: [String] = []
if sqlite3_prepare_v2(oldStore.db, "PRAGMA table_info(local_files);", -1, &stmt, nil) == SQLITE_OK {
    while sqlite3_step(stmt) == SQLITE_ROW {
        cols.append(String(cString: sqlite3_column_text(stmt, 1)))
    }
    sqlite3_finalize(stmt)
}
assert(!cols.contains("sync_status"), "Old schema unexpectedly contains sync_status")
print("  ✓ Confirmed old schema lacks sync_status column (reproduces pre-migration bug)")

// Now perform migration
oldStore.migrateSchema()
cols = []
if sqlite3_prepare_v2(oldStore.db, "PRAGMA table_info(local_files);", -1, &stmt, nil) == SQLITE_OK {
    while sqlite3_step(stmt) == SQLITE_ROW {
        cols.append(String(cString: sqlite3_column_text(stmt, 1)))
    }
    sqlite3_finalize(stmt)
}
assert(cols.contains("sync_status"), "Migration failed to add sync_status")
assert(cols.contains("album"), "Migration failed to add album")
assert(cols.contains("is_favorite"), "Migration failed to add is_favorite")
print("  ✓ Schema migration successfully added all missing columns to existing table")

// ── TEST 2: Exact Workflow from User Specification ──
print("\n[TEST 2] Testing Exact Workflow (Downloads -> photo1, photo2, Netflix/folder1, Netflix/folder2)...")
let downloadsDir = tempDir.appendingPathComponent("Downloads")
let netflixDir = downloadsDir.appendingPathComponent("Netflix")
let folder1 = netflixDir.appendingPathComponent("folder1")
let folder2 = netflixDir.appendingPathComponent("folder2")

try! FileManager.default.createDirectory(at: folder1, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: folder2, withIntermediateDirectories: true)

let photo1Path = downloadsDir.appendingPathComponent("photo1.jpg").path
let photo2Path = downloadsDir.appendingPathComponent("photo2.jpg").path
let clip1Path = folder1.appendingPathComponent("clip1.mp4").path
let clip2Path = folder2.appendingPathComponent("clip2.mp4").path

try! "photo1 data".write(toFile: photo1Path, atomically: true, encoding: .utf8)
try! "photo2 data".write(toFile: photo2Path, atomically: true, encoding: .utf8)
try! "clip1 video data".write(toFile: clip1Path, atomically: true, encoding: .utf8)
try! "clip2 video data".write(toFile: clip2Path, atomically: true, encoding: .utf8)

let scanner = TestScanner(cacheStore: oldStore)

// Step 1: Initial scan of Downloads
var downloadsState = scanner.scanDirectory(directoryPath: downloadsDir.path)
assert(downloadsState["photo1.jpg"] == .uncommitted, "photo1 should initially be uncommitted")
assert(downloadsState["photo2.jpg"] == .uncommitted, "photo2 should initially be uncommitted")
assert(downloadsState["Netflix"] == .uncommitted, "Netflix should initially be uncommitted")
print("  ✓ Initial scan: photo1, photo2, and Netflix are correctly uncommitted (✕)")

// Step 2: Sync photo1.jpg and photo2.jpg
oldStore.markSynced(paths: [photo1Path, photo2Path], status: .committed)
downloadsState = scanner.scanDirectory(directoryPath: downloadsDir.path)
assert(downloadsState["photo1.jpg"] == .committed, "photo1 must show committed")
assert(downloadsState["photo2.jpg"] == .committed, "photo2 must show committed")
assert(downloadsState["Netflix"] == .uncommitted, "Netflix must still be uncommitted")
print("  ✓ After syncing photos: photo1 (✓), photo2 (✓), Netflix (✕)")

// Step 3: Open Netflix (navigate inside)
var netflixState = scanner.scanDirectory(directoryPath: netflixDir.path)
assert(netflixState["folder1"] == .uncommitted, "folder1 must be uncommitted")
assert(netflixState["folder2"] == .uncommitted, "folder2 must be uncommitted")
print("  ✓ Inside Netflix: folder1 (✕), folder2 (✕)")

// Step 4: Open nested folder1
var folder1State = scanner.scanDirectory(directoryPath: folder1.path)
assert(folder1State["clip1.mp4"] == .uncommitted, "clip1.mp4 must be uncommitted")
print("  ✓ Inside folder1: clip1.mp4 (✕)")

// Step 5: Return all the way to Downloads
downloadsState = scanner.scanDirectory(directoryPath: downloadsDir.path)
assert(downloadsState["photo1.jpg"] == .committed, "photo1.jpg MUST STILL show committed (✓)")
assert(downloadsState["photo2.jpg"] == .committed, "photo2.jpg MUST STILL show committed (✓)")
assert(downloadsState["Netflix"] == .uncommitted, "Netflix is uncommitted")
print("  ✓ Returned to Downloads: photo1.jpg (✓) and photo2.jpg (✓) PERSISTED after navigating deep and returning!")

// Step 6: Sync Netflix (sync all nested files)
oldStore.markSynced(paths: [clip1Path, clip2Path], status: .committed)

// Step 7: Re-scan Downloads
downloadsState = scanner.scanDirectory(directoryPath: downloadsDir.path)
assert(downloadsState["Netflix"] == .committed, "Netflix folder MUST derive committed (✓) from all synced contents")
assert(downloadsState["photo1.jpg"] == .committed, "photo1.jpg remains committed (✓)")
assert(downloadsState["photo2.jpg"] == .committed, "photo2.jpg remains committed (✓)")
print("  ✓ Synced Netflix: Downloads shows photo1 (✓), photo2 (✓), Netflix (✓)")

// Step 8: Repeated navigation into and out of Netflix
for _ in 1...3 {
    let insideNetflix = scanner.scanDirectory(directoryPath: netflixDir.path)
    assert(insideNetflix["folder1"] == .committed, "folder1 must show committed")
    assert(insideNetflix["folder2"] == .committed, "folder2 must show committed")
    
    let backToDownloads = scanner.scanDirectory(directoryPath: downloadsDir.path)
    assert(backToDownloads["Netflix"] == .committed, "Netflix must remain committed")
    assert(backToDownloads["photo1.jpg"] == .committed, "photo1 must remain committed")
    assert(backToDownloads["photo2.jpg"] == .committed, "photo2 must remain committed")
}
print("  ✓ Repeated navigation into and out of Netflix maintains correct sync state across all 3 iterations")

// ── TEST 3: App Restart Persistence ──
print("\n[TEST 3] Testing App Restart State Persistence...")
// Create brand new store instance pointing to same SQLite database
let restartedStore = TestCacheStore(dbPath: dbFile, simulateOldSchema: false)
let restartedScanner = TestScanner(cacheStore: restartedStore)

let restartedDownloads = restartedScanner.scanDirectory(directoryPath: downloadsDir.path)
assert(restartedDownloads["photo1.jpg"] == .committed, "photo1 must survive restart as committed (✓)")
assert(restartedDownloads["photo2.jpg"] == .committed, "photo2 must survive restart as committed (✓)")
assert(restartedDownloads["Netflix"] == .committed, "Netflix folder must survive restart as committed (✓)")

let restartedNetflix = restartedScanner.scanDirectory(directoryPath: netflixDir.path)
assert(restartedNetflix["folder1"] == .committed, "folder1 must survive restart as committed (✓)")
assert(restartedNetflix["folder2"] == .committed, "folder2 must survive restart as committed (✓)")
print("  ✓ All file and recursive folder sync states survive app restart completely intact!")

// ── TEST 4: Partial Sync and File Modification Invalidation ──
print("\n[TEST 4] Testing File Invalidation and Partial Folder Sync...")
// Add an unsynced file to folder1
let newClip = folder1.appendingPathComponent("clip3_new.mp4").path
try! "new unsynced clip".write(toFile: newClip, atomically: true, encoding: .utf8)

let invalidatedNetflix = restartedScanner.scanDirectory(directoryPath: netflixDir.path)
assert(invalidatedNetflix["folder1"] == .uncommitted, "folder1 must become uncommitted when containing a new unsynced file")
assert(invalidatedNetflix["folder2"] == .committed, "folder2 must remain committed")

let invalidatedDownloads = restartedScanner.scanDirectory(directoryPath: downloadsDir.path)
assert(invalidatedDownloads["Netflix"] == .uncommitted, "Netflix must become uncommitted when any nested file is unsynced")
assert(invalidatedDownloads["photo1.jpg"] == .committed, "photo1.jpg remains committed (✓)")
assert(invalidatedDownloads["photo2.jpg"] == .committed, "photo2.jpg remains committed (✓)")
print("  ✓ Partial sync / modification correctly invalidates containing folder while preserving unaffected files")

print("\n🎉 ALL 4 TESTS PASSED SUCCESSFULLY!")
