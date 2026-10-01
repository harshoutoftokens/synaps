import Foundation
import SQLite3

public final class LocalCacheStore {
    public static let shared = LocalCacheStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.synaps.cachestore", qos: .userInitiated)
    
    public struct CachedRecord {
        public let path: String
        public let inode: Int64
        public let size: Int64
        public let mtime: Double
        public let sha256: String?
        public let lastSyncedAt: Double?
        public let syncStatus: String
        public let album: String?
        public let isFavorite: Bool
    }
    
    private init() {
        openDatabase()
        createTables()
        migrateSchema()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func openDatabase() {
        let dir = SynapsConfig.configDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("client_state.db").path
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("❌ Failed to open SQLite cache database at \(dbPath)")
        }
    }
    
    private func createTables() {
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
        CREATE TABLE IF NOT EXISTS sync_activity_log (
            id TEXT PRIMARY KEY,
            timestamp REAL NOT NULL,
            event_type TEXT NOT NULL,
            file_path TEXT,
            filename TEXT,
            details TEXT,
            source_id TEXT
        );
        CREATE INDEX IF NOT EXISTS ix_activity_timestamp ON sync_activity_log (timestamp DESC);
        """
        queue.sync {
            var errMsg: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
                if let err = errMsg {
                    print("SQLite table init error: \(String(cString: err))")
                    sqlite3_free(err)
                }
            }
        }
    }
    
    private func migrateSchema() {
        queue.sync {
            var existingColumns = Set<String>()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(local_files);", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let colName = sqlite3_column_text(stmt, 1) {
                        existingColumns.insert(String(cString: colName).lowercased())
                    }
                }
                sqlite3_finalize(stmt)
            } else if let err = sqlite3_errmsg(db) {
                print("❌ SQLite PRAGMA table_info error: \(String(cString: err))")
            }
            
            let migrations: [(col: String, alterSql: String)] = [
                ("sync_status", "ALTER TABLE local_files ADD COLUMN sync_status TEXT DEFAULT 'uncommitted';"),
                ("album", "ALTER TABLE local_files ADD COLUMN album TEXT;"),
                ("is_favorite", "ALTER TABLE local_files ADD COLUMN is_favorite INTEGER DEFAULT 0;")
            ]
            
            for migration in migrations {
                if !existingColumns.contains(migration.col) {
                    var errMsg: UnsafeMutablePointer<CChar>?
                    if sqlite3_exec(db, migration.alterSql, nil, nil, &errMsg) == SQLITE_OK {
                        print("✅ Added missing column \(migration.col) to local_files")
                    } else if let err = errMsg {
                        print("❌ Migration error adding \(migration.col): \(String(cString: err))")
                        sqlite3_free(err)
                    }
                }
            }
            
            _ = sqlite3_exec(db, "CREATE INDEX IF NOT EXISTS ix_sync_status ON local_files (sync_status);", nil, nil, nil)
        }
    }
    
    public static func normalizePath(_ path: String) -> String {
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
    
    public func getRecord(for path: String) -> CachedRecord? {
        let norm = Self.normalizePath(path)
        return queue.sync {
            let sql = "SELECT path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite FROM local_files WHERE path = ? OR path = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let err = sqlite3_errmsg(db) {
                    print("❌ SQLite getRecord prepare error for \(path): \(String(cString: err))")
                }
                return nil
            }
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
    }
    
    public func saveRecord(_ record: CachedRecord) {
        let norm = Self.normalizePath(record.path)
        queue.sync {
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
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let err = sqlite3_errmsg(db) {
                    print("❌ SQLite saveRecord prepare error for \(record.path): \(String(cString: err))")
                }
                return
            }
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
            
            if sqlite3_step(stmt) != SQLITE_DONE {
                if let err = sqlite3_errmsg(db) {
                    print("❌ SQLite saveRecord step error for \(record.path): \(String(cString: err))")
                }
            }
        }
    }
    
    public func markSynced(paths: [String], status: SyncStatus = .committed) {
        let now = Date().timeIntervalSince1970
        let fileManager = FileManager.default
        queue.sync {
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
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                if let err = sqlite3_errmsg(db) {
                    print("❌ SQLite markSynced prepare error: \(String(cString: err))")
                }
                return
            }
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
                if sqlite3_step(stmt) != SQLITE_DONE {
                    if let err = sqlite3_errmsg(db) {
                        print("❌ SQLite markSynced step error for \(path): \(String(cString: err))")
                    }
                }
            }
        }
    }
    
    public func recordItemSynced(
        path: String,
        fileSize: Int64,
        modifiedAt: Date,
        sha256: String?,
        album: String? = nil,
        isFavorite: Bool = false
    ) {
        let norm = Self.normalizePath(path)
        let fileManager = FileManager.default
        let stat = (try? fileManager.attributesOfItem(atPath: norm)) ?? (try? fileManager.attributesOfItem(atPath: path))
        let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        let now = Date().timeIntervalSince1970
        
        saveRecord(CachedRecord(
            path: norm,
            inode: inode,
            size: fileSize,
            mtime: modifiedAt.timeIntervalSince1970,
            sha256: sha256,
            lastSyncedAt: now,
            syncStatus: SyncStatus.committed.rawValue,
            album: album,
            isFavorite: isFavorite
        ))
    }
    
    public func logActivity(
        eventType: SyncActivityItem.SyncActivityType,
        filePath: String? = nil,
        filename: String? = nil,
        details: String,
        sourceId: String? = nil
    ) {
        let item = SyncActivityItem(
            eventType: eventType,
            filePath: filePath,
            filename: filename,
            details: details,
            sourceId: sourceId
        )
        queue.sync {
            let sql = """
            INSERT INTO sync_activity_log (id, timestamp, event_type, file_path, filename, details, source_id)
            VALUES (?, ?, ?, ?, ?, ?, ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 3, (item.eventType.rawValue as NSString).utf8String, -1, nil)
            
            if let p = item.filePath {
                sqlite3_bind_text(stmt, 4, (p as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            
            if let f = item.filename {
                sqlite3_bind_text(stmt, 5, (f as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            
            sqlite3_bind_text(stmt, 6, (item.details as NSString).utf8String, -1, nil)
            
            if let s = item.sourceId {
                sqlite3_bind_text(stmt, 7, (s as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 7)
            }
            
            sqlite3_step(stmt)
        }
    }
    
    public func getRecentActivity(limit: Int = 100) -> [SyncActivityItem] {
        return queue.sync {
            let sql = """
            SELECT id, timestamp, event_type, file_path, filename, details, source_id
            FROM sync_activity_log
            ORDER BY timestamp DESC
            LIMIT ?;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_int(stmt, 1, Int32(limit))
            
            var results: [SyncActivityItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let t = sqlite3_column_double(stmt, 1)
                let typeStr = String(cString: sqlite3_column_text(stmt, 2))
                let type = SyncActivityItem.SyncActivityType(rawValue: typeStr) ?? .statusReconciled
                let path = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                let filename = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                let details = String(cString: sqlite3_column_text(stmt, 5))
                let source = sqlite3_column_text(stmt, 6).map { String(cString: $0) }
                
                results.append(SyncActivityItem(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: t),
                    eventType: type,
                    filePath: path,
                    filename: filename,
                    details: details,
                    sourceId: source
                ))
            }
            return results
        }
    }
    
    public func clearActivityLog() {
        queue.sync {
            let sql = "DELETE FROM sync_activity_log;"
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }
}
