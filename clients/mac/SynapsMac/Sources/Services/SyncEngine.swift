import Foundation

/// Runs a commit (upload) pass entirely off the main thread, in chunks of ≤200 files:
/// 1. hashes files that have no SHA-256 yet (streaming, bounded parallelism),
/// 2. asks the NAS which hashes it already has (`/api/v2/ingest/check`, one request per chunk),
/// 3. uploads the rest from disk with bounded concurrency (2: the NAS is a dual-core box with a
///    single disk, more parallel uploads just thrash it), retrying transient failures with
///    exponential backoff.
/// Cancelling the calling task stops hashing and in-flight uploads promptly.
public final class SyncEngine: @unchecked Sendable {
    public struct Options: Sendable {
        public var uploadConcurrency = 2
        public var hashConcurrency = HashEngine.defaultParallelism
        public var checkBatchSize = NASClient.maxCheckBatchSize
        public var maxUploadAttempts = 3
        /// First retry waits about this long, then doubles (with jitter).
        public var retryBaseDelay: Double = 2.0
        /// Link committed files that carry an album name (e.g. "iPhone Import") on the NAS.
        public var syncAlbums = true
        public var friendlyName = "Harsh's Mac"
        public var platform = "macOS"
        
        public init() {}
    }
    
    public enum Outcome: Sendable, Equatable {
        case uploaded
        case alreadyOnNAS
        case failed(String)
        case cancelled
    }
    
    public struct ItemResult: Sendable {
        /// The item as processed (with its SHA-256 filled in when it could be computed).
        public let item: SynapsFileItem
        public let outcome: Outcome
    }
    
    public struct Progress: Sendable {
        public var completedFiles = 0
        public var totalFiles = 0
        public var completedBytes: Int64 = 0
        public var totalBytes: Int64 = 0
        public var bytesPerSecond: Double = 0
        public var message = ""
        
        /// Byte-weighted so a 4 GB video counts for more than a 4 KB text file.
        public var fraction: Double {
            if totalBytes > 0 {
                return min(1.0, Double(completedBytes) / Double(totalBytes))
            }
            return totalFiles > 0 ? min(1.0, Double(completedFiles) / Double(totalFiles)) : 0
        }
    }
    
    public struct Summary: Sendable {
        public var uploaded = 0
        public var alreadyOnNAS = 0
        public var failed = 0
        public var cancelled = 0
        public var bytesUploaded: Int64 = 0
        public var elapsed: TimeInterval = 0
        /// The run stopped early: the NAS answered 401 (API token missing or wrong)...
        public var unauthorized = false
        /// ...or 507 (its disk is full).
        public var diskFull = false
        
        public var committed: Int { uploaded + alreadyOnNAS }
    }
    
    /// Item events are batched and delivered with each progress tick (every ~300 ms) so the UI
    /// updates a few times per second, not once per file.
    public enum Event: Sendable {
        case progress(Progress)
        /// Paths whose upload started.
        case started([String])
        case finished([ItemResult])
    }
    
    static let unauthorizedMessage = "API token missing or wrong — check Settings"
    static let diskFullMessage = "Home Cloud's disk is full"
    
    private let client: NASClient
    private let cacheStore: LocalCacheStore
    
    public init(client: NASClient = .shared, cacheStore: LocalCacheStore = .shared) {
        self.client = client
        self.cacheStore = cacheStore
    }
    
    public func run(
        items: [SynapsFileItem],
        options: Options = Options(),
        onEvent: @escaping @Sendable (Event) async -> Void
    ) async -> Summary {
        let start = Date()
        let state = RunState(
            totalFiles: items.count,
            totalBytes: items.reduce(Int64(0)) { $0 + max(0, $1.fileSize) }
        )
        
        // Progress and item events are sampled on a timer instead of per callback.
        let reporter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if Task.isCancelled { break }
                await Self.flush(state, onEvent)
            }
        }
        defer { reporter.cancel() }
        
        let batchSize = max(1, options.checkBatchSize)
        var index = 0
        while index < items.count {
            let chunk = Array(items[index..<min(index + batchSize, items.count)])
            index += chunk.count
            
            if let reason = state.abortReason {
                state.finish(chunk.map { ItemResult(item: $0, outcome: .failed(reason)) })
                continue
            }
            if Task.isCancelled {
                state.finish(chunk.map { ItemResult(item: $0, outcome: .cancelled) })
                continue
            }
            
            // 1. Hash what isn't hashed yet
            var hashed: [SynapsFileItem] = []
            var unreadable: [ItemResult] = []
            let missing = chunk.filter { ($0.sha256 ?? "").isEmpty }.map { $0.originalPath }
            if !missing.isEmpty {
                state.setMessage("Hashing \(missing.count) file\(missing.count == 1 ? "" : "s")...")
                let hashes = await HashEngine.computeSHA256s(for: missing, maxConcurrent: options.hashConcurrency)
                for var item in chunk {
                    if (item.sha256 ?? "").isEmpty {
                        item.sha256 = hashes[item.originalPath]
                    }
                    if item.sha256 != nil {
                        hashed.append(item)
                    } else {
                        unreadable.append(ItemResult(item: item, outcome: Task.isCancelled ? .cancelled : .failed("Could not read file to hash it")))
                    }
                }
            } else {
                hashed = chunk
            }
            state.finish(unreadable)
            if Task.isCancelled {
                state.finish(hashed.map { ItemResult(item: $0, outcome: .cancelled) })
                continue
            }
            
            // 2. Ask the NAS which of these it already has (zero-transfer dedup)
            var toUpload = hashed
            if !hashed.isEmpty {
                state.setMessage("Checking \(hashed.count) file\(hashed.count == 1 ? "" : "s") with Home Cloud...")
                do {
                    toUpload = try await linkKnownContent(hashed, options: options, state: state)
                } catch NASClientError.unauthorized {
                    if state.markUnauthorized() {
                        cacheStore.logActivity(
                            eventType: .syncFailed,
                            details: "Sync stopped: \(NASClientError.unauthorized.localizedDescription)",
                            sourceId: hashed.first?.sourceId
                        )
                    }
                    state.finish(hashed.map { ItemResult(item: $0, outcome: .failed(Self.unauthorizedMessage)) })
                    continue
                } catch let error where NASClient.isCancellation(error) {
                    state.finish(hashed.map { ItemResult(item: $0, outcome: .cancelled) })
                    continue
                } catch {
                    // Pre-check unavailable: upload everything (the server dedups by hash anyway).
                    print("⚠️ [SyncEngine] Pre-check failed, uploading chunk directly: \(error.localizedDescription)")
                    cacheStore.logActivity(
                        eventType: .syncFailed,
                        details: "NAS pre-check failed, uploading \(hashed.count) files without dedup: \(error.localizedDescription)",
                        sourceId: hashed.first?.sourceId
                    )
                }
            }
            
            // Identical content in this chunk is uploaded once; the copies are linked afterwards by
            // another pre-check (saves the transfer and avoids two parallel uploads of the same hash).
            var seenHashes = Set<String>()
            var primaries: [SynapsFileItem] = []
            var duplicates: [SynapsFileItem] = []
            for item in toUpload {
                if seenHashes.insert(item.sha256 ?? item.originalPath).inserted {
                    primaries.append(item)
                } else {
                    duplicates.append(item)
                }
            }
            
            // 3. Upload the rest, `uploadConcurrency` at a time
            await uploadAll(primaries, options: options, state: state)
            
            if !duplicates.isEmpty {
                var leftovers = duplicates
                if !Task.isCancelled && state.abortReason == nil,
                   let remaining = try? await linkKnownContent(duplicates, options: options, state: state) {
                    leftovers = remaining
                }
                // Primary upload failed (or the check did): upload the copies themselves
                await uploadAll(leftovers, options: options, state: state)
            }
        }
        
        if options.syncAlbums && !Task.isCancelled && state.abortReason == nil {
            await syncAlbumMemberships(state.committedWithAlbum, state: state)
        }
        
        reporter.cancel()
        state.setMessage("")
        await Self.flush(state, onEvent)
        
        var summary = state.summary
        summary.elapsed = Date().timeIntervalSince(start)
        return summary
    }
    
    private static func flush(_ state: RunState, _ onEvent: @Sendable (Event) async -> Void) async {
        let (started, finished) = state.drainEvents()
        if !started.isEmpty {
            await onEvent(.started(started))
        }
        if !finished.isEmpty {
            await onEvent(.finished(finished))
        }
        await onEvent(.progress(state.snapshot()))
    }
    
    /// Pre-checks `items`, records the ones the NAS already has as committed (cache, activity log,
    /// outcome) and returns the rest.
    private func linkKnownContent(_ items: [SynapsFileItem], options: Options, state: RunState) async throws -> [SynapsFileItem] {
        let response = try await client.batchPreCheck(
            sourceId: items.first?.sourceId ?? "mac_harsh",
            friendlyName: options.friendlyName,
            platform: options.platform,
            items: items
        )
        let dedupPaths = Set(response.results.filter { $0.status == "dedup_linked" }.map { $0.original_path })
        let linked = items.filter { dedupPaths.contains($0.originalPath) }
        if !linked.isEmpty {
            cacheStore.recordItemsSynced(linked)
            cacheStore.logActivities(linked.map {
                SyncActivityItem(
                    eventType: .existingDiscovered,
                    filePath: $0.originalPath,
                    filename: $0.filename,
                    details: "Existing file detected on NAS (dedup linked)",
                    sourceId: $0.sourceId
                )
            })
            state.finish(linked.map { ItemResult(item: $0, outcome: .alreadyOnNAS) })
        }
        return items.filter { !dedupPaths.contains($0.originalPath) }
    }
    
    private func uploadAll(_ items: [SynapsFileItem], options: Options, state: RunState) async {
        guard !items.isEmpty else { return }
        await withTaskGroup(of: ItemResult.self) { group in
            var iterator = items.makeIterator()
            
            func addNext() -> Bool {
                guard let next = iterator.next() else { return false }
                group.addTask {
                    return await self.uploadOne(next, options: options, state: state)
                }
                return true
            }
            
            for _ in 0..<max(1, options.uploadConcurrency) {
                if !addNext() { break }
            }
            while let result = await group.next() {
                state.finish([result])
                _ = addNext()
            }
        }
    }
    
    /// One /api/v2/ingest/albums call per (source, album); failures go to the activity log with the
    /// server's reason.
    private func syncAlbumMemberships(_ items: [SynapsFileItem], state: RunState) async {
        var groups: [String: (sourceId: String, album: String, paths: [String])] = [:]
        for item in items {
            guard let album = item.albumName, !album.isEmpty else { continue }
            let key = item.sourceId + "\u{1F}" + album
            groups[key, default: (item.sourceId, album, [])].paths.append(item.originalPath)
        }
        for group in groups.values.sorted(by: { $0.album < $1.album }) {
            guard !Task.isCancelled else { return }
            state.setMessage("Updating album \(group.album)...")
            do {
                try await client.syncAlbums(sourceId: group.sourceId, albumName: group.album, originalPaths: group.paths)
            } catch {
                print("⚠️ [SyncEngine] Album sync failed for \(group.album): \(error.localizedDescription)")
                cacheStore.logActivity(
                    eventType: .syncFailed,
                    details: "Album sync failed for \"\(group.album)\" (\(group.paths.count) files): \(error.localizedDescription)",
                    sourceId: group.sourceId
                )
            }
        }
    }
    
    private func uploadOne(_ original: SynapsFileItem, options: Options, state: RunState) async -> ItemResult {
        var item = original
        let path = item.originalPath
        var attempt = 0
        var rehashed = false
        
        if let reason = state.abortReason {
            return ItemResult(item: item, outcome: .failed(reason))
        }
        if Task.isCancelled {
            return ItemResult(item: item, outcome: .cancelled)
        }
        state.started(path)
        
        while true {
            attempt += 1
            state.setMessage("Uploading \(item.filename)...")
            do {
                let result = try await client.uploadFile(item: item, sourceId: item.sourceId) { sent, _ in
                    state.updateInFlight(path: path, sentBytes: sent)
                }
                state.finishUpload(path: path, bytes: item.fileSize)
                if let serverSha = result.sha256, !serverSha.isEmpty {
                    item.sha256 = serverSha
                }
                cacheStore.recordItemSynced(
                    path: item.originalPath,
                    fileSize: item.fileSize,
                    modifiedAt: item.modifiedAt,
                    sha256: item.sha256,
                    album: item.albumName,
                    isFavorite: item.isFavorite
                )
                cacheStore.logActivity(
                    eventType: .fileSynced,
                    filePath: item.originalPath,
                    filename: item.filename,
                    details: "Uploaded \(item.formattedSize) to NAS Vault",
                    sourceId: item.sourceId
                )
                return ItemResult(item: item, outcome: .uploaded)
            } catch {
                state.clearInFlight(path: path)
                
                if NASClient.isCancellation(error) || Task.isCancelled {
                    return ItemResult(item: item, outcome: .cancelled)
                }
                if let clientError = error as? NASClientError, clientError == .unauthorized {
                    if state.markUnauthorized() {
                        cacheStore.logActivity(
                            eventType: .syncFailed,
                            details: "Sync stopped: \(clientError.localizedDescription)",
                            sourceId: item.sourceId
                        )
                    }
                    return ItemResult(item: item, outcome: .failed(Self.unauthorizedMessage))
                }
                // Out of space: every further upload would fail too, so stop the batch.
                if let clientError = error as? NASClientError, clientError.isDiskFull {
                    if state.markDiskFull() {
                        cacheStore.logActivity(
                            eventType: .syncFailed,
                            filePath: item.originalPath,
                            filename: item.filename,
                            details: "Sync stopped: \(clientError.localizedDescription)",
                            sourceId: item.sourceId
                        )
                    }
                    return ItemResult(item: item, outcome: .failed(Self.diskFullMessage))
                }
                // A 400 usually means the bytes no longer match client_sha256 (the file changed
                // after it was hashed). Rather than depend on the wording of the server's message,
                // hash again: if the content changed, retry once with the new hash.
                if case NASClientError.httpStatus(400, _)? = error as? NASClientError, !rehashed {
                    rehashed = true
                    if let freshSha = await HashEngine.computeSHA256s(for: [path], maxConcurrent: 1)[path],
                       freshSha != item.sha256 {
                        item.sha256 = freshSha
                        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
                            item.fileSize = (attrs[.size] as? NSNumber)?.int64Value ?? item.fileSize
                            item.modifiedAt = (attrs[.modificationDate] as? Date) ?? item.modifiedAt
                        }
                        continue
                    }
                }
                if NASClient.isTransient(error) && attempt < options.maxUploadAttempts {
                    state.setMessage("Retrying \(item.filename) (\(error.localizedDescription))...")
                    do {
                        try await Task.sleep(nanoseconds: NASClient.backoffNanoseconds(attempt: attempt, base: options.retryBaseDelay))
                    } catch {
                        return ItemResult(item: item, outcome: .cancelled)
                    }
                    continue
                }
                
                cacheStore.logActivity(
                    eventType: .syncFailed,
                    filePath: item.originalPath,
                    filename: item.filename,
                    details: "Upload error: \(error.localizedDescription)",
                    sourceId: item.sourceId
                )
                return ItemResult(item: item, outcome: .failed(error.localizedDescription))
            }
        }
    }
}

/// Thread-safe state of one run: progress/throughput, the summary, and item events waiting to be
/// delivered with the next progress tick.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: SyncEngine.Progress
    private var inFlight: [String: Int64] = [:]
    /// Bytes of finished uploads (deduplicated files don't count towards throughput).
    private var uploadedSoFar: Int64 = 0
    private var lastSampleTime = Date()
    private var lastSampleBytes: Int64 = 0
    private var smoothedRate: Double = 0
    private var result = SyncEngine.Summary()
    private var albumItems: [SynapsFileItem] = []
    private var pendingStarted: [String] = []
    private var pendingFinished: [SyncEngine.ItemResult] = []
    
    init(totalFiles: Int, totalBytes: Int64) {
        progress = SyncEngine.Progress(totalFiles: totalFiles, totalBytes: totalBytes)
    }
    
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
    
    var summary: SyncEngine.Summary { locked { result } }
    /// Committed files that belong to an album.
    var committedWithAlbum: [SynapsFileItem] { locked { albumItems } }
    
    /// Why the run stopped early (401 or 507), if it did.
    var abortReason: String? {
        return locked {
            if result.unauthorized {
                return SyncEngine.unauthorizedMessage
            }
            return result.diskFull ? SyncEngine.diskFullMessage : nil
        }
    }
    
    /// Returns true for the first call only (so the activity log gets one entry).
    @discardableResult
    func markUnauthorized() -> Bool {
        return locked {
            defer { result.unauthorized = true }
            return !result.unauthorized
        }
    }
    
    @discardableResult
    func markDiskFull() -> Bool {
        return locked {
            defer { result.diskFull = true }
            return !result.diskFull
        }
    }
    
    func setMessage(_ message: String) {
        locked { progress.message = message }
    }
    
    func started(_ path: String) {
        locked { pendingStarted.append(path) }
    }
    
    func updateInFlight(path: String, sentBytes: Int64) {
        locked { inFlight[path] = sentBytes }
    }
    
    func clearInFlight(path: String) {
        locked { inFlight[path] = nil }
    }
    
    /// Moves a finished upload's bytes from in-flight to uploaded in one step so throughput
    /// sampling never sees them disappear.
    func finishUpload(path: String, bytes: Int64) {
        locked {
            inFlight[path] = nil
            uploadedSoFar += max(0, bytes)
            result.bytesUploaded += max(0, bytes)
        }
    }
    
    /// Records final outcomes (exactly one per item) and queues them for the UI.
    func finish(_ results: [SyncEngine.ItemResult]) {
        guard !results.isEmpty else { return }
        locked {
            for r in results {
                inFlight[r.item.originalPath] = nil
                progress.completedFiles += 1
                progress.completedBytes += max(0, r.item.fileSize)
                switch r.outcome {
                case .uploaded: result.uploaded += 1
                case .alreadyOnNAS: result.alreadyOnNAS += 1
                case .failed: result.failed += 1
                case .cancelled: result.cancelled += 1
                }
                if r.outcome == .uploaded || r.outcome == .alreadyOnNAS, r.item.albumName != nil {
                    albumItems.append(r.item)
                }
            }
            pendingFinished.append(contentsOf: results)
        }
    }
    
    func drainEvents() -> (started: [String], finished: [SyncEngine.ItemResult]) {
        return locked {
            defer {
                pendingStarted.removeAll()
                pendingFinished.removeAll()
            }
            return (pendingStarted, pendingFinished)
        }
    }
    
    func snapshot() -> SyncEngine.Progress {
        return locked {
            var snap = progress
            let inFlightBytes = inFlight.values.reduce(0, +)
            snap.completedBytes = min(snap.totalBytes, progress.completedBytes + inFlightBytes)
            
            // Exponentially smoothed throughput of bytes actually sent.
            let now = Date()
            let sent = uploadedSoFar + inFlightBytes
            let dt = now.timeIntervalSince(lastSampleTime)
            if dt >= 0.25 {
                let instant = Double(max(0, sent - lastSampleBytes)) / dt
                smoothedRate = smoothedRate == 0 ? instant : (0.7 * smoothedRate + 0.3 * instant)
                lastSampleTime = now
                lastSampleBytes = sent
            }
            snap.bytesPerSecond = smoothedRate
            return snap
        }
    }
}
