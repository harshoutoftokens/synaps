import Foundation
import SQLite3

public final class LocalCacheStore: @unchecked Sendable {
    public static let shared = LocalCacheStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.synaps.ios.cachestore", qos: .userInitiated)
    
    public struct CachedRecord: Sendable {
        public let id: String
        public let filename: String
        public let size: Int64
        public let mtime: Double
        public let sha256: String?
        public let lastSyncedAt: Double?
        public let syncStatus: String
        public let isFavorite: Bool
    }
    
    private init() {
        openDatabase()
        createTables()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func getDatabaseURL() -> URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Synaps", isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("synaps_ios_state.db")
    }
    
    private func openDatabase() {
        let dbURL = getDatabaseURL()
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("❌ Failed to open SQLite cache database at \(dbURL.path)")
        }
    }
    
    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS local_assets (
            id TEXT PRIMARY KEY,
            filename TEXT,
            size INTEGER,
            mtime REAL,
            sha256 TEXT,
            last_synced_at REAL,
            sync_status TEXT DEFAULT 'uncommitted',
            is_favorite INTEGER DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS ix_assets_sha256 ON local_assets (sha256);
        CREATE INDEX IF NOT EXISTS ix_assets_sync_status ON local_assets (sync_status);
        
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
    
    public func getRecord(id: String) -> CachedRecord? {
        return queue.sync {
            var stmt: OpaquePointer?
            let sql = "SELECT id, filename, size, mtime, sha256, last_synced_at, sync_status, is_favorite FROM local_assets WHERE id = ? LIMIT 1;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                let rId = String(cString: sqlite3_column_text(stmt, 0))
                let filename = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
                let size = sqlite3_column_int64(stmt, 2)
                let mtime = sqlite3_column_double(stmt, 3)
                let sha = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
                let syncedAt = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_double(stmt, 5) : nil
                let status = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "uncommitted"
                let isFav = sqlite3_column_int(stmt, 7) == 1
                return CachedRecord(id: rId, filename: filename, size: size, mtime: mtime, sha256: sha, lastSyncedAt: syncedAt, syncStatus: status, isFavorite: isFav)
            }
            return nil
        }
    }
    
    public func getAllRecords() -> [String: CachedRecord] {
        return queue.sync {
            var results: [String: CachedRecord] = [:]
            var stmt: OpaquePointer?
            let sql = "SELECT id, filename, size, mtime, sha256, last_synced_at, sync_status, is_favorite FROM local_assets;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
            defer { sqlite3_finalize(stmt) }
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rId = String(cString: sqlite3_column_text(stmt, 0))
                let filename = sqlite3_column_text(stmt, 1).flatMap { String(cString: $0) } ?? ""
                let size = sqlite3_column_int64(stmt, 2)
                let mtime = sqlite3_column_double(stmt, 3)
                let sha = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) }
                let syncedAt = sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_double(stmt, 5) : nil
                let status = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "uncommitted"
                let isFav = sqlite3_column_int(stmt, 7) == 1
                results[rId] = CachedRecord(id: rId, filename: filename, size: size, mtime: mtime, sha256: sha, lastSyncedAt: syncedAt, syncStatus: status, isFavorite: isFav)
            }
            return results
        }
    }
    
    public func upsertRecord(id: String, filename: String, size: Int64, mtime: Double, sha256: String?, syncStatus: SyncStatus, isFavorite: Bool) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = """
            INSERT INTO local_assets (id, filename, size, mtime, sha256, last_synced_at, sync_status, is_favorite)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                filename = excluded.filename,
                size = excluded.size,
                mtime = excluded.mtime,
                sha256 = COALESCE(excluded.sha256, local_assets.sha256),
                last_synced_at = CASE WHEN excluded.sync_status = 'committed' THEN strftime('%s','now') ELSE local_assets.last_synced_at END,
                sync_status = excluded.sync_status,
                is_favorite = excluded.is_favorite;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (filename as NSString).utf8String, -1, nil)
            sqlite3_bind_int64(stmt, 3, size)
            sqlite3_bind_double(stmt, 4, mtime)
            
            if let sha = sha256 {
                sqlite3_bind_text(stmt, 5, (sha as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            
            if syncStatus == .committed {
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            
            sqlite3_bind_text(stmt, 7, (syncStatus.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_int(stmt, 8, isFavorite ? 1 : 0)
            
            _ = sqlite3_step(stmt)
        }
    }
    
    public func updateSyncStatus(id: String, status: SyncStatus, sha256: String? = nil) {
        queue.sync {
            var stmt: OpaquePointer?
            let sql: String
            if status == .committed {
                sql = "UPDATE local_assets SET sync_status = ?, last_synced_at = strftime('%s','now')" + (sha256 != nil ? ", sha256 = ?" : "") + " WHERE id = ?;"
            } else {
                sql = "UPDATE local_assets SET sync_status = ?" + (sha256 != nil ? ", sha256 = ?" : "") + " WHERE id = ?;"
            }
            
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, nil)
            if let sha = sha256 {
                sqlite3_bind_text(stmt, 2, (sha as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_text(stmt, 2, (id as NSString).utf8String, -1, nil)
            }
            
            _ = sqlite3_step(stmt)
        }
    }
    
    public func logActivity(eventType: SyncActivityItem.EventType, filePath: String, filename: String, details: String, sourceId: String = "iphone_harsh") {
        queue.sync {
            var stmt: OpaquePointer?
            let sql = "INSERT INTO sync_activity_log (id, timestamp, event_type, file_path, filename, details, source_id) VALUES (?, ?, ?, ?, ?, ?, ?);"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            let id = UUID().uuidString
            let ts = Date().timeIntervalSince1970
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 2, ts)
            sqlite3_bind_text(stmt, 3, (eventType.rawValue as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 4, (filePath as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 5, (filename as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 6, (details as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 7, (sourceId as NSString).utf8String, -1, nil)
            
            _ = sqlite3_step(stmt)
        }
    }
    
    public func getRecentActivities(limit: Int = 100) -> [SyncActivityItem] {
        return queue.sync {
            var list: [SyncActivityItem] = []
            var stmt: OpaquePointer?
            let sql = "SELECT id, timestamp, event_type, file_path, filename, details, source_id FROM sync_activity_log ORDER BY timestamp DESC LIMIT ?;"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return list }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_int(stmt, 1, Int32(limit))
            
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let evtStr = String(cString: sqlite3_column_text(stmt, 2))
                let eventType = SyncActivityItem.EventType(rawValue: evtStr) ?? .uploaded
                let filePath = sqlite3_column_text(stmt, 3).flatMap { String(cString: $0) } ?? ""
                let filename = sqlite3_column_text(stmt, 4).flatMap { String(cString: $0) } ?? ""
                let details = sqlite3_column_text(stmt, 5).flatMap { String(cString: $0) } ?? ""
                let sourceId = sqlite3_column_text(stmt, 6).flatMap { String(cString: $0) } ?? "iphone_harsh"
                
                list.append(SyncActivityItem(id: id, timestamp: ts, eventType: eventType, filePath: filePath, filename: filename, details: details, sourceId: sourceId))
            }
            return list
        }
    }
    
    public func clearActivityLog() {
        queue.sync {
            _ = sqlite3_exec(db, "DELETE FROM sync_activity_log;", nil, nil, nil)
        }
    }
}
