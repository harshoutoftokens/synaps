import Foundation
import SQLite3

/// SQLite copies bound text immediately with SQLITE_TRANSIENT. Binding with nil (SQLITE_STATIC)
/// requires the buffer to outlive the statement, which a temporary bridged NSString does not.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// All database access is serialized on `queue`, so the store can be shared across threads.
public final class LocalCacheStore: @unchecked Sendable {
    public static let shared = LocalCacheStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.synaps.cachestore", qos: .userInitiated)
    
    /// Activity rows kept on disk; older ones are pruned at launch.
    private static let maxActivityRows = 5000
    
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
        
        /// True when the record proves this exact content (size + mtime) is on the NAS.
        public func isCommitted(size: Int64, mtime: Double) -> Bool {
            return (syncStatus == SyncStatus.committed.rawValue || lastSyncedAt != nil)
                && self.size == size
                && abs(self.mtime - mtime) < 1.0
        }
    }
    
    private convenience init() {
        self.init(databaseURL: SynapsConfig.configDir.appendingPathComponent("client_state.db"))
    }
    
    /// Opens (or creates) the cache database at `databaseURL`. Tests pass a temporary location.
    init(databaseURL: URL) {
        openDatabase(at: databaseURL)
        createTables()
        migrateSchema()
        pruneActivityLog()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    private func openDatabase(at url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dbPath = url.path
        
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("❌ Failed to open SQLite cache database at \(dbPath)")
            return
        }
        // The legacy Python client may hold the file briefly; wait instead of failing writes.
        sqlite3_busy_timeout(db, 3000)
        // WAL + NORMAL turns each small write into an append instead of a full journal fsync.
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;", nil, nil, nil)
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
    
    private func pruneActivityLog() {
        queue.sync {
            let sql = """
            DELETE FROM sync_activity_log WHERE timestamp < (
                SELECT timestamp FROM sync_activity_log ORDER BY timestamp DESC LIMIT 1 OFFSET \(Self.maxActivityRows - 1)
            );
            """
            _ = sqlite3_exec(db, sql, nil, nil, nil)
        }
    }
    
    public static func normalizePath(_ path: String) -> String {
        // Virtual keys (iPhone://...) aren't file paths; treating them as relative paths made the
        // stored key depend on the process's working directory.
        if path.contains("://") {
            return path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
    
    // MARK: - Binding helpers (must be called on `queue`)
    
    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value = value {
            sqlite3_bind_text(stmt, index, value, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }
    
    /// Runs `body` inside one transaction so batches cost a single commit.
    private func inTransaction(_ body: () -> Void) {
        queue.sync {
            let began = sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK
            body()
            if began {
                _ = sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            }
        }
    }
    
    private func readRecord(_ stmt: OpaquePointer?) -> CachedRecord? {
        guard let p = columnText(stmt, 0) else { return nil }
        return CachedRecord(
            path: p,
            inode: sqlite3_column_int64(stmt, 1),
            size: sqlite3_column_int64(stmt, 2),
            mtime: sqlite3_column_double(stmt, 3),
            sha256: columnText(stmt, 4),
            lastSyncedAt: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? sqlite3_column_double(stmt, 5) : nil,
            syncStatus: columnText(stmt, 6) ?? SyncStatus.uncommitted.rawValue,
            album: columnText(stmt, 7),
            isFavorite: sqlite3_column_int(stmt, 8) != 0
        )
    }
    
    // MARK: - Records
    
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
            
            bindText(stmt, 1, norm)
            bindText(stmt, 2, path)
            
            if sqlite3_step(stmt) == SQLITE_ROW {
                return readRecord(stmt)
            }
            return nil
        }
    }
    
    /// All records stored below `folderPath` (any depth) in one indexed range query, keyed by path.
    /// Used to evaluate folder status without one lookup per file.
    public func records(under folderPath: String) -> [String: CachedRecord] {
        var prefix = Self.normalizePath(folderPath)
        if !prefix.hasSuffix("/") {
            prefix += "/"
        }
        // Every path starting with "<folder>/" sorts between "<folder>/" and "<folder>0" ('/' + 1).
        let upper = String(prefix.dropLast()) + "0"
        return queue.sync {
            var result: [String: CachedRecord] = [:]
            let sql = "SELECT path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite FROM local_files WHERE path >= ? AND path < ?;"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return result }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, prefix)
            bindText(stmt, 2, upper)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let record = readRecord(stmt) {
                    result[record.path] = record
                }
            }
            return result
        }
    }
    
    public func saveRecord(_ record: CachedRecord) {
        queue.sync {
            saveRecordLocked(record)
        }
    }
    
    public func saveRecords(_ records: [CachedRecord]) {
        guard !records.isEmpty else { return }
        inTransaction {
            for record in records {
                saveRecordLocked(record)
            }
        }
    }
    
    private func saveRecordLocked(_ record: CachedRecord) {
        let norm = Self.normalizePath(record.path)
        // A record only stays "committed" while it describes the same content. If size, mtime or
        // hash changed, the caller's status/last_synced_at/sha win; otherwise "committed" is sticky.
        let changed = """
        (excluded.size != IFNULL(local_files.size, -1)
         OR abs(excluded.mtime - IFNULL(local_files.mtime, -1)) >= 1.0
         OR (excluded.sha256 IS NOT NULL AND local_files.sha256 IS NOT NULL AND excluded.sha256 != local_files.sha256))
        """
        let sql = """
        INSERT INTO local_files (path, inode, size, mtime, sha256, last_synced_at, sync_status, album, is_favorite)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            inode = excluded.inode,
            size = excluded.size,
            mtime = excluded.mtime,
            sha256 = CASE WHEN \(changed) THEN excluded.sha256
                          ELSE COALESCE(excluded.sha256, local_files.sha256) END,
            last_synced_at = CASE WHEN \(changed) THEN excluded.last_synced_at
                                  ELSE COALESCE(excluded.last_synced_at, local_files.last_synced_at) END,
            sync_status = CASE
                WHEN local_files.sync_status = 'committed' AND excluded.sync_status = 'uncommitted'
                     AND NOT \(changed) THEN 'committed'
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
        
        bindText(stmt, 1, norm)
        sqlite3_bind_int64(stmt, 2, record.inode)
        sqlite3_bind_int64(stmt, 3, record.size)
        sqlite3_bind_double(stmt, 4, record.mtime)
        bindText(stmt, 5, record.sha256)
        if let syncedAt = record.lastSyncedAt {
            sqlite3_bind_double(stmt, 6, syncedAt)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, record.syncStatus)
        bindText(stmt, 8, record.album)
        sqlite3_bind_int(stmt, 9, record.isFavorite ? 1 : 0)
        
        if sqlite3_step(stmt) != SQLITE_DONE {
            if let err = sqlite3_errmsg(db) {
                print("❌ SQLite saveRecord step error for \(record.path): \(String(cString: err))")
            }
        }
    }
    
    public func markSynced(paths: [String], status: SyncStatus = .committed) {
        let now = Date().timeIntervalSince1970
        let fileManager = FileManager.default
        inTransaction {
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
                bindText(stmt, 1, norm)
                sqlite3_bind_int64(stmt, 2, inode)
                sqlite3_bind_int64(stmt, 3, size)
                sqlite3_bind_double(stmt, 4, mtime)
                sqlite3_bind_null(stmt, 5)
                if status == .uncommitted {
                    sqlite3_bind_null(stmt, 6)
                } else {
                    sqlite3_bind_double(stmt, 6, now)
                }
                bindText(stmt, 7, status.rawValue)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    if let err = sqlite3_errmsg(db) {
                        print("❌ SQLite markSynced step error for \(path): \(String(cString: err))")
                    }
                }
            }
        }
    }
    
    public func updateSyncStatus(path: String, status: SyncStatus) {
        updateSyncStatuses(paths: [path], status: status)
    }
    
    /// With `notSyncedSince`, rows committed at or after that time are left alone: a sync that
    /// committed a file while a reconciliation request was in flight must win over its stale answer.
    public func updateSyncStatuses(paths: [String], status: SyncStatus, notSyncedSince cutoff: Date? = nil) {
        guard !paths.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        let pairs = paths.map { (Self.normalizePath($0), $0) }
        inTransaction {
            let guardClause = cutoff == nil ? "" : " AND (last_synced_at IS NULL OR last_synced_at < ?)"
            let sql = """
            UPDATE local_files
            SET sync_status = ?,
                last_synced_at = ?
            WHERE (path = ? OR path = ?)\(guardClause);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            
            for (norm, raw) in pairs {
                sqlite3_reset(stmt)
                bindText(stmt, 1, status.rawValue)
                if status == .committed {
                    sqlite3_bind_double(stmt, 2, now)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                bindText(stmt, 3, norm)
                bindText(stmt, 4, raw)
                if let cutoff = cutoff {
                    sqlite3_bind_double(stmt, 5, cutoff.timeIntervalSince1970)
                }
                _ = sqlite3_step(stmt)
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
        saveRecord(Self.committedRecord(
            path: path,
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            sha256: sha256,
            album: album,
            isFavorite: isFavorite
        ))
    }
    
    /// Batch variant of `recordItemSynced` (one transaction).
    public func recordItemsSynced(_ items: [SynapsFileItem]) {
        saveRecords(items.map {
            Self.committedRecord(
                path: $0.originalPath,
                fileSize: $0.fileSize,
                modifiedAt: $0.modifiedAt,
                sha256: $0.sha256,
                album: $0.albumName,
                isFavorite: $0.isFavorite
            )
        })
    }
    
    private static func committedRecord(
        path: String,
        fileSize: Int64,
        modifiedAt: Date,
        sha256: String?,
        album: String?,
        isFavorite: Bool
    ) -> CachedRecord {
        let norm = normalizePath(path)
        let fileManager = FileManager.default
        let stat = (try? fileManager.attributesOfItem(atPath: norm)) ?? (try? fileManager.attributesOfItem(atPath: path))
        let inode = (stat?[.systemFileNumber] as? NSNumber)?.int64Value ?? 0
        return CachedRecord(
            path: norm,
            inode: inode,
            size: fileSize,
            mtime: modifiedAt.timeIntervalSince1970,
            sha256: sha256,
            lastSyncedAt: Date().timeIntervalSince1970,
            syncStatus: SyncStatus.committed.rawValue,
            album: album,
            isFavorite: isFavorite
        )
    }
    
    // MARK: - Activity log
    
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
            insertActivityLocked(item)
        }
    }
    
    /// Batch variant of `logActivity` (one transaction).
    public func logActivities(_ items: [SyncActivityItem]) {
        guard !items.isEmpty else { return }
        inTransaction {
            for item in items {
                insertActivityLocked(item)
            }
        }
    }
    
    private func insertActivityLocked(_ item: SyncActivityItem) {
        let sql = """
        INSERT INTO sync_activity_log (id, timestamp, event_type, file_path, filename, details, source_id)
        VALUES (?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        
        bindText(stmt, 1, item.id)
        sqlite3_bind_double(stmt, 2, item.timestamp.timeIntervalSince1970)
        bindText(stmt, 3, item.eventType.rawValue)
        bindText(stmt, 4, item.filePath)
        bindText(stmt, 5, item.filename)
        bindText(stmt, 6, item.details)
        bindText(stmt, 7, item.sourceId)
        
        sqlite3_step(stmt)
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
                guard let id = columnText(stmt, 0) else { continue }
                let t = sqlite3_column_double(stmt, 1)
                let typeStr = columnText(stmt, 2) ?? ""
                let type = SyncActivityItem.SyncActivityType(rawValue: typeStr) ?? .statusReconciled
                
                results.append(SyncActivityItem(
                    id: id,
                    timestamp: Date(timeIntervalSince1970: t),
                    eventType: type,
                    filePath: columnText(stmt, 3),
                    filename: columnText(stmt, 4),
                    details: columnText(stmt, 5) ?? "",
                    sourceId: columnText(stmt, 6)
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
