import Foundation
import SQLite3

/// Local SQLite state: per-asset sync status, per-part hash cache / commit state, activity log.
/// All access is serialized on `queue`.
public final class LocalCacheStore: @unchecked Sendable {
    public static let shared = LocalCacheStore()
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.synaps.ios.cachestore", qos: .userInitiated)
    private var activityInsertsSincePrune = 0
    
    /// Bump when the part-scanning rules change so assets get re-scanned once.
    public static let currentPartsVersion = 1
    private static let maxActivityRows = 2000
    
    public struct CachedRecord: Sendable {
        public let id: String
        public let filename: String
        public let size: Int64
        public let mtime: Double
        public let sha256: String?
        public let lastSyncedAt: Double?
        public let syncStatus: String
        public let isFavorite: Bool
        public let failCount: Int
        public let lastAttemptAt: Double?
        public let lastError: String?
        public let partsVersion: Int
    }
    
    /// Result of reading an asset's resources from PhotoKit (hash/commit fields unset).
    public struct ResourceScan: Sendable {
        public let assetId: String
        public let mtime: Double
        public let isFavorite: Bool
        public let parts: [AssetPart]
        
        public init(assetId: String, mtime: Double, isFavorite: Bool, parts: [AssetPart]) {
            self.assetId = assetId
            self.mtime = mtime
            self.isFavorite = isFavorite
            self.parts = parts
        }
    }
    
    public struct AssetState: Sendable {
        public let record: CachedRecord
        public let parts: [AssetPart]
    }
    
    private init() {
        openDatabase()
        createTables()
        migrate()
    }
    
    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }
    
    // MARK: - Setup
    
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
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
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(dbURL.path, &db, flags, nil) != SQLITE_OK {
            print("❌ Failed to open SQLite cache database at \(dbURL.path)")
            return
        }
        // WAL + NORMAL: one fsync per checkpoint instead of per statement; safe for a cache.
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
        sqlite3_busy_timeout(db, 3000)
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
        
        CREATE TABLE IF NOT EXISTS asset_parts (
            asset_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            filename TEXT NOT NULL,
            size INTEGER NOT NULL DEFAULT 0,
            is_primary INTEGER NOT NULL DEFAULT 0,
            sha256 TEXT,
            hash_mtime REAL,
            committed_at REAL,
            PRIMARY KEY (asset_id, kind)
        );
        
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
            _ = exec(sql)
        }
    }
    
    /// Adds columns introduced after v1 to existing databases.
    private func migrate() {
        queue.sync {
            var existing = Set<String>()
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "PRAGMA table_info(local_assets);", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let name = columnText(stmt, 1) {
                        existing.insert(name)
                    }
                }
            }
            sqlite3_finalize(stmt)
            
            let additions: [(String, String)] = [
                ("fail_count", "INTEGER DEFAULT 0"),
                ("last_attempt_at", "REAL"),
                ("last_error", "TEXT"),
                ("parts_version", "INTEGER DEFAULT 0")
            ]
            for (column, type) in additions where !existing.contains(column) {
                exec("ALTER TABLE local_assets ADD COLUMN \(column) \(type);")
            }
            // `syncing` is transient; a crash or cancelled run must not leave assets stuck in it.
            exec("UPDATE local_assets SET sync_status = 'uncommitted' WHERE sync_status = 'syncing';")
        }
    }
    
    // MARK: - Low-level helpers (call on `queue` only)
    
    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            if let err = errMsg {
                print("SQLite error: \(String(cString: err)) in \(sql.prefix(80))")
                sqlite3_free(err)
            }
            return false
        }
        return true
    }
    
    private func inTransaction<T>(_ body: () -> T) -> T {
        exec("BEGIN IMMEDIATE;")
        let result = body()
        if !exec("COMMIT;") {
            exec("ROLLBACK;")
        }
        return result
    }
    
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }
    
    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int64) {
        sqlite3_bind_int64(stmt, index, value)
    }
    
    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }
    
    private func columnDouble(_ stmt: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
    }
    
    /// Runs `sql`, binding with `binder`, and calls `row` for each result row.
    private func query(_ sql: String, binder: (OpaquePointer?) -> Void = { _ in }, row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            row(stmt)
        }
    }
    
    @discardableResult
    private func run(_ sql: String, binder: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            print("SQLite prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        binder(stmt)
        return sqlite3_step(stmt) == SQLITE_DONE
    }
    
    private static let recordColumns = "id, filename, size, mtime, sha256, last_synced_at, sync_status, is_favorite, fail_count, last_attempt_at, last_error, parts_version"
    
    private func readRecord(_ stmt: OpaquePointer?) -> CachedRecord? {
        guard let id = columnText(stmt, 0) else { return nil }
        return CachedRecord(
            id: id,
            filename: columnText(stmt, 1) ?? "",
            size: sqlite3_column_int64(stmt, 2),
            mtime: sqlite3_column_double(stmt, 3),
            sha256: columnText(stmt, 4),
            lastSyncedAt: columnDouble(stmt, 5),
            syncStatus: columnText(stmt, 6) ?? SyncStatus.uncommitted.rawValue,
            isFavorite: sqlite3_column_int(stmt, 7) == 1,
            failCount: Int(sqlite3_column_int(stmt, 8)),
            lastAttemptAt: columnDouble(stmt, 9),
            lastError: columnText(stmt, 10),
            partsVersion: Int(sqlite3_column_int(stmt, 11))
        )
    }
    
    private static let partColumns = "asset_id, kind, filename, size, is_primary, sha256, hash_mtime, committed_at"
    
    private func readPart(_ stmt: OpaquePointer?) -> AssetPart? {
        guard let assetId = columnText(stmt, 0),
              let kindRaw = columnText(stmt, 1),
              let kind = AssetPartKind(rawValue: kindRaw) else { return nil }
        return AssetPart(
            assetId: assetId,
            kind: kind,
            filename: columnText(stmt, 2) ?? "",
            size: sqlite3_column_int64(stmt, 3),
            isPrimary: sqlite3_column_int(stmt, 4) == 1,
            sha256: columnText(stmt, 5),
            hashMtime: columnDouble(stmt, 6),
            committedAt: columnDouble(stmt, 7)
        )
    }
    
    private func recordUnlocked(id: String) -> CachedRecord? {
        var result: CachedRecord?
        query("SELECT \(Self.recordColumns) FROM local_assets WHERE id = ? LIMIT 1;", binder: { self.bind($0, 1, id) }) { stmt in
            result = self.readRecord(stmt)
        }
        return result
    }
    
    private func partsUnlocked(assetId: String) -> [AssetPart] {
        var parts: [AssetPart] = []
        query("SELECT \(Self.partColumns) FROM asset_parts WHERE asset_id = ?;", binder: { self.bind($0, 1, assetId) }) { stmt in
            if let part = self.readPart(stmt) { parts.append(part) }
        }
        return parts
    }
    
    // MARK: - Reads
    
    public func getRecord(id: String) -> CachedRecord? {
        queue.sync { recordUnlocked(id: id) }
    }
    
    public func getAllRecords() -> [String: CachedRecord] {
        queue.sync {
            var results: [String: CachedRecord] = [:]
            query("SELECT \(Self.recordColumns) FROM local_assets;") { stmt in
                if let rec = self.readRecord(stmt) { results[rec.id] = rec }
            }
            return results
        }
    }
    
    public func getAllParts() -> [String: [AssetPart]] {
        queue.sync {
            var results: [String: [AssetPart]] = [:]
            query("SELECT \(Self.partColumns) FROM asset_parts;") { stmt in
                if let part = self.readPart(stmt) { results[part.assetId, default: []].append(part) }
            }
            return results
        }
    }
    
    public func getParts(assetId: String) -> [AssetPart] {
        queue.sync { partsUnlocked(assetId: assetId) }
    }
    
    /// Records + parts for a set of assets (missing assets are omitted).
    public func getStates(assetIds: [String]) -> [String: AssetState] {
        queue.sync {
            var out: [String: AssetState] = [:]
            for id in assetIds {
                if let rec = recordUnlocked(id: id) {
                    out[id] = AssetState(record: rec, parts: partsUnlocked(assetId: id))
                }
            }
            return out
        }
    }
    
    /// Failed assets that automatic syncs should skip for now (exponential backoff: 15 min, 30 min, ... capped at 24 h).
    public func assetIdsInFailureBackoff(now: Date = Date()) -> Set<String> {
        queue.sync {
            var ids = Set<String>()
            let nowTs = now.timeIntervalSince1970
            query("SELECT id, fail_count, last_attempt_at FROM local_assets WHERE sync_status = 'failed';") { stmt in
                guard let id = self.columnText(stmt, 0) else { return }
                let failCount = max(1, Int(sqlite3_column_int(stmt, 1)))
                let lastAttempt = self.columnDouble(stmt, 2) ?? 0
                let backoff = min(15 * 60 * pow(2.0, Double(min(failCount - 1, 10))), 24 * 3600)
                if nowTs - lastAttempt < backoff {
                    ids.insert(id)
                }
            }
            return ids
        }
    }
    
    // MARK: - Writes
    
    /// Merges freshly scanned resources into the stored parts, keeping cached hashes / commit
    /// marks that are still valid, and updates the asset rows. Runs as one transaction and
    /// returns the merged state so callers can refresh their in-memory copies.
    @discardableResult
    public func applyResourceScans(_ scans: [ResourceScan], policy: PartPolicy) -> [String: AssetState] {
        guard !scans.isEmpty else { return [:] }
        return queue.sync {
            inTransaction {
                var out: [String: AssetState] = [:]
                for scan in scans {
                    let previous = recordUnlocked(id: scan.assetId)
                    let oldParts = Dictionary(partsUnlocked(assetId: scan.assetId).map { ($0.kind, $0) }, uniquingKeysWith: { a, _ in a })
                    
                    var merged: [AssetPart] = []
                    for var part in scan.parts {
                        if let old = oldParts[part.kind], old.hashIsValid(size: part.size, mtime: scan.mtime) {
                            part.sha256 = old.sha256
                            part.hashMtime = old.hashMtime
                            part.committedAt = old.committedAt
                        } else if oldParts.isEmpty, part.isPrimary, let legacy = previous, legacy.partsVersion == 0,
                                  let legacySha = legacy.sha256, legacy.size == 0 || legacy.size == part.size {
                            // Rows written by v1 tracked only the primary resource. Its hash describes the
                            // immutable original, so carry it (and a committed mark) over.
                            part.sha256 = legacySha
                            part.hashMtime = legacy.mtime
                            if legacy.syncStatus == SyncStatus.committed.rawValue {
                                part.committedAt = legacy.lastSyncedAt ?? Date().timeIntervalSince1970
                            }
                        }
                        merged.append(part)
                    }
                    
                    run("DELETE FROM asset_parts WHERE asset_id = ?;") { self.bind($0, 1, scan.assetId) }
                    for part in merged {
                        run("INSERT INTO asset_parts (\(Self.partColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?);") { stmt in
                            self.bind(stmt, 1, part.assetId)
                            self.bind(stmt, 2, part.kind.rawValue)
                            self.bind(stmt, 3, part.filename)
                            self.bind(stmt, 4, part.size)
                            sqlite3_bind_int(stmt, 5, part.isPrimary ? 1 : 0)
                            self.bind(stmt, 6, part.sha256)
                            self.bind(stmt, 7, part.hashMtime)
                            self.bind(stmt, 8, part.committedAt)
                        }
                    }
                    
                    let primary = merged.first(where: { $0.isPrimary })
                    let lastFailed = previous?.syncStatus == SyncStatus.failed.rawValue
                    let status = policy.status(for: merged, lastAttemptFailed: lastFailed)
                    run("""
                        INSERT INTO local_assets (id, filename, size, mtime, sha256, sync_status, is_favorite, parts_version)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET
                            filename = excluded.filename,
                            size = excluded.size,
                            mtime = excluded.mtime,
                            sha256 = excluded.sha256,
                            sync_status = excluded.sync_status,
                            is_favorite = excluded.is_favorite,
                            parts_version = excluded.parts_version;
                        """) { stmt in
                        self.bind(stmt, 1, scan.assetId)
                        self.bind(stmt, 2, primary?.filename ?? previous?.filename ?? "")
                        self.bind(stmt, 3, primary?.size ?? 0)
                        self.bind(stmt, 4, scan.mtime)
                        self.bind(stmt, 5, primary?.sha256)
                        self.bind(stmt, 6, status.rawValue)
                        sqlite3_bind_int(stmt, 7, scan.isFavorite ? 1 : 0)
                        sqlite3_bind_int(stmt, 8, Int32(Self.currentPartsVersion))
                    }
                    if let rec = recordUnlocked(id: scan.assetId) {
                        out[scan.assetId] = AssetState(record: rec, parts: merged)
                    }
                }
                return out
            }
        }
    }
    
    /// Stores a freshly computed hash for a part. A changed hash invalidates its commit mark.
    public func setPartHash(assetId: String, kind: AssetPartKind, sha256: String, size: Int64, hashMtime: Double) {
        queue.sync {
            run("""
                UPDATE asset_parts SET
                    committed_at = CASE WHEN sha256 = ?1 THEN committed_at ELSE NULL END,
                    sha256 = ?1, size = ?2, hash_mtime = ?3
                WHERE asset_id = ?4 AND kind = ?5;
                """) { stmt in
                self.bind(stmt, 1, sha256)
                self.bind(stmt, 2, size)
                self.bind(stmt, 3, hashMtime)
                self.bind(stmt, 4, assetId)
                self.bind(stmt, 5, kind.rawValue)
            }
            run("UPDATE local_assets SET sha256 = ? WHERE id = ? AND EXISTS (SELECT 1 FROM asset_parts WHERE asset_id = ? AND kind = ? AND is_primary = 1);") { stmt in
                self.bind(stmt, 1, sha256)
                self.bind(stmt, 2, assetId)
                self.bind(stmt, 3, assetId)
                self.bind(stmt, 4, kind.rawValue)
            }
        }
    }
    
    /// Marks parts as present on the NAS (uploaded or dedup-linked) with the given content hash.
    public func markPartsCommitted(_ refs: [(assetId: String, kind: AssetPartKind, sha256: String)]) {
        guard !refs.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        queue.sync {
            inTransaction {
                for ref in refs {
                    run("UPDATE asset_parts SET committed_at = ?, sha256 = ? WHERE asset_id = ? AND kind = ?;") { stmt in
                        self.bind(stmt, 1, now)
                        self.bind(stmt, 2, ref.sha256)
                        self.bind(stmt, 3, ref.assetId)
                        self.bind(stmt, 4, ref.kind.rawValue)
                    }
                }
            }
        }
    }
    
    /// Re-derives an asset's status from its parts and records the outcome of a sync attempt.
    /// `error` non-nil marks the attempt failed (feeds the automatic-sync backoff).
    @discardableResult
    public func recordAttempt(assetId: String, policy: PartPolicy, error: String?) -> SyncStatus {
        let now = Date().timeIntervalSince1970
        return queue.sync {
            let parts = partsUnlocked(assetId: assetId)
            let status = policy.status(for: parts, lastAttemptFailed: error != nil)
            switch status {
            case .committed:
                run("""
                    INSERT INTO local_assets (id, sync_status, last_synced_at, last_attempt_at, fail_count, last_error)
                    VALUES (?1, 'committed', ?2, ?2, 0, NULL)
                    ON CONFLICT(id) DO UPDATE SET sync_status = 'committed', last_synced_at = ?2,
                        last_attempt_at = ?2, fail_count = 0, last_error = NULL;
                    """) { stmt in
                    self.bind(stmt, 1, assetId)
                    self.bind(stmt, 2, now)
                }
            case .failed:
                run("""
                    INSERT INTO local_assets (id, sync_status, last_attempt_at, fail_count, last_error)
                    VALUES (?1, 'failed', ?2, 1, ?3)
                    ON CONFLICT(id) DO UPDATE SET sync_status = 'failed', last_attempt_at = ?2,
                        fail_count = COALESCE(fail_count, 0) + 1, last_error = ?3;
                    """) { stmt in
                    self.bind(stmt, 1, assetId)
                    self.bind(stmt, 2, now)
                    self.bind(stmt, 3, error)
                }
            case .uncommitted, .syncing:
                run("UPDATE local_assets SET sync_status = 'uncommitted' WHERE id = ? AND sync_status != 'failed';") { stmt in
                    self.bind(stmt, 1, assetId)
                }
            }
            return status
        }
    }
    
    /// Re-derives every scanned asset's status after the part policy changed (Settings toggles).
    public func recomputeStatuses(policy: PartPolicy) {
        let parts = getAllParts()
        queue.sync {
            inTransaction {
                var updates: [(String, SyncStatus)] = []
                query("SELECT id, sync_status FROM local_assets WHERE parts_version > 0;") { stmt in
                    guard let id = self.columnText(stmt, 0) else { return }
                    let failed = self.columnText(stmt, 1) == SyncStatus.failed.rawValue
                    updates.append((id, policy.status(for: parts[id] ?? [], lastAttemptFailed: failed)))
                }
                for (id, status) in updates {
                    run("UPDATE local_assets SET sync_status = ? WHERE id = ?;") { stmt in
                        self.bind(stmt, 1, status.rawValue)
                        self.bind(stmt, 2, id)
                    }
                }
            }
        }
    }
    
    // MARK: - Activity log
    
    public func logActivity(eventType: SyncActivityItem.EventType, filePath: String, filename: String, details: String, sourceId: String = "iphone_harsh") {
        queue.sync {
            run("INSERT INTO sync_activity_log (id, timestamp, event_type, file_path, filename, details, source_id) VALUES (?, ?, ?, ?, ?, ?, ?);") { stmt in
                self.bind(stmt, 1, UUID().uuidString)
                self.bind(stmt, 2, Date().timeIntervalSince1970)
                self.bind(stmt, 3, eventType.rawValue)
                self.bind(stmt, 4, filePath)
                self.bind(stmt, 5, filename)
                self.bind(stmt, 6, details)
                self.bind(stmt, 7, sourceId)
            }
            activityInsertsSincePrune += 1
            if activityInsertsSincePrune >= 200 {
                activityInsertsSincePrune = 0
                exec("DELETE FROM sync_activity_log WHERE id NOT IN (SELECT id FROM sync_activity_log ORDER BY timestamp DESC LIMIT \(Self.maxActivityRows));")
            }
        }
    }
    
    public func getRecentActivities(limit: Int = 100) -> [SyncActivityItem] {
        queue.sync {
            var list: [SyncActivityItem] = []
            query("SELECT id, timestamp, event_type, file_path, filename, details, source_id FROM sync_activity_log ORDER BY timestamp DESC LIMIT ?;", binder: {
                sqlite3_bind_int($0, 1, Int32(limit))
            }) { stmt in
                guard let id = self.columnText(stmt, 0) else { return }
                let ts = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
                let eventType = SyncActivityItem.EventType(rawValue: self.columnText(stmt, 2) ?? "") ?? .uploaded
                list.append(SyncActivityItem(
                    id: id,
                    timestamp: ts,
                    eventType: eventType,
                    filePath: self.columnText(stmt, 3) ?? "",
                    filename: self.columnText(stmt, 4) ?? "",
                    details: self.columnText(stmt, 5) ?? "",
                    sourceId: self.columnText(stmt, 6) ?? "iphone_harsh"
                ))
            }
            return list
        }
    }
    
    public func clearActivityLog() {
        queue.sync {
            _ = exec("DELETE FROM sync_activity_log;")
        }
    }
}
