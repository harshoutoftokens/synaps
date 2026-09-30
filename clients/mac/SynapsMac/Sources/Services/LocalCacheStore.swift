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
    
    public func getRecord(for path: String) -> CachedRecord? {
        return queue.sync {
            let sql = "SELECT path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite FROM local_files WHERE path = ? LIMIT 1;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (path as NSString).utf8String, -1, nil)
            
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
                sync_status = excluded.sync_status,
                album = COALESCE(excluded.album, local_files.album),
                is_favorite = excluded.is_favorite;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            sqlite3_bind_text(stmt, 1, (record.path as NSString).utf8String, -1, nil)
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
            
            sqlite3_step(stmt)
        }
    }
    
    public func markSynced(paths: [String], status: SyncStatus = .committed) {
        let now = Date().timeIntervalSince1970
        queue.sync {
            let sql = "UPDATE local_files SET sync_status = ?, last_synced_at = ? WHERE path = ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            for path in paths {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, (status.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 2, now)
                sqlite3_bind_text(stmt, 3, (path as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
        }
    }
}
