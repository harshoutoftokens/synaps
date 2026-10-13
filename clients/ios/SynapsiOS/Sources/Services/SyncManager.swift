import Foundation
import Combine
import Photos
import UIKit

/// Coordinates hashing, NAS pre-check and uploads. All state lives on the main actor; heavy
/// work (exports, hashing, network) runs off-main.
///
/// Pipeline per window (≤200 parts, bounded staging bytes):
///  A. export + hash parts without a cached hash (hash cached by asset, resource size, mtime)
///  B. one POST /api/v2/ingest/check for the window -> dedup-linked parts commit instantly
///  C. upload the rest via the background URLSession (≤2 connections), PUT /stream with
///     multipart fallback, retrying transient failures with exponential backoff
@MainActor
public final class SyncManager: ObservableObject {
    public static let shared = SyncManager()
    
    public enum Trigger: Sendable {
        case manual
        case automatic
    }
    
    @Published public private(set) var isSyncing: Bool = false
    @Published public private(set) var currentProgress: Double = 0.0
    @Published public private(set) var currentItemName: String = ""
    @Published public private(set) var syncedCount: Int = 0
    @Published public private(set) var totalToSyncCount: Int = 0
    @Published public private(set) var isConnectedToNAS: Bool = false
    /// Why the last run stopped early (NAS unreachable, token rejected, left Wi-Fi...), if it did.
    @Published public private(set) var statusMessage: String?
    
    private var queue: [String] = []
    private var queued: Set<String> = []
    /// Requests that arrived while a cancelled run was winding down; started right after it.
    private var deferredIds: [String] = []
    private var deferredManual = false
    private var runTask: Task<Void, Never>?
    private var runIsManual = false
    private var stopRequested = false
    private var abortRequested = false
    private var committedInRun = 0
    private var idleWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    
    private static let maxPartsPerWindow = 200   // also the /api/v2/ingest/check batch size
    private static let maxQueuedUploads = 6      // handed to the background session at once (≤2 run concurrently)
    nonisolated private static let maxAttempts = 3
    
    private init() {}
    
    // MARK: - Public API
    
    public func checkNASStatus() async {
        isConnectedToNAS = await NASClient.shared.checkHealth()
    }
    
    /// Queues items for upload. If a sync is already running they join it (a single-photo
    /// "Commit" no longer cancels a running batch).
    public func syncItems(_ items: [SynapsMediaItem], trigger: Trigger = .manual) {
        enqueue(items.map { $0.id }, trigger: trigger)
    }
    
    /// User-initiated cancel: stops the run and cancels in-flight uploads.
    public func cancelSync() {
        stopRequested = true
        abortRequested = true
        dropQueue()
        deferredIds.removeAll()
        runTask?.cancel()
        Task {
            await UploadSessionManager.shared.cancelAll()
        }
    }
    
    public func clearStatusMessage() {
        statusMessage = nil
    }
    
    /// Background-time expiry: finish the current step but leave already-enqueued uploads
    /// running in the background URLSession.
    public func stopAfterCurrentStep() {
        stopRequested = true
    }
    
    /// Queues eligible items when automatic upload conditions hold (Auto-Upload on, unmetered
    /// Wi-Fi/Ethernet, charging if required, NAS reachable). Returns true if anything was queued.
    @discardableResult
    public func requestAutomaticSync(limit: Int? = nil) async -> Bool {
        if await automaticSyncBlocker() != nil {
            return false
        }
        let online = await NASClient.shared.checkHealth()
        isConnectedToNAS = online
        guard online else { return false } // e.g. on someone else's Wi-Fi: stay quiet
        
        let library = PhotoLibraryService.shared
        await library.ensureLoaded()
        let inBackoff = await Task.detached(priority: .utility) {
            LocalCacheStore.shared.assetIdsInFailureBackoff()
        }.value
        let favoritesOnly = SynapsConfig.load().syncFavoritesOnly
        var candidates = library.mediaItems.filter { item in
            (item.syncStatus == .uncommitted || item.syncStatus == .failed)
                && !inBackoff.contains(item.id)
                && !queued.contains(item.id)
                && (!favoritesOnly || item.isFavorite)
        }
        if let limit {
            candidates = Array(candidates.prefix(limit)) // newest first
        }
        guard !candidates.isEmpty else { return false }
        enqueue(candidates.map { $0.id }, trigger: .automatic)
        return true
    }
    
    /// BGTask entry point. Returns false if the run ended with a problem.
    public func runBackgroundSync(limit: Int?, timeout: TimeInterval?) async -> Bool {
        guard SynapsConfig.load().backgroundTaskEnabled else { return true }
        let queuedWork = await requestAutomaticSync(limit: limit)
        guard queuedWork || isSyncing else { return true } // nothing to do (or not on home Wi-Fi)
        await waitUntilIdle(timeout: timeout)
        return statusMessage == nil
    }
    
    /// Waits until no run is active (or `timeout` elapses, or the caller is cancelled).
    public func waitUntilIdle(timeout: TimeInterval? = nil) async {
        guard runTask != nil else { return }
        guard let timeout else {
            await waitForIdle()
            return
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.waitForIdle() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }
    
    public func appDidBecomeActive() {
        PhotoLibraryService.shared.refreshAuthorizationStatus()
        Task {
            await checkNASStatus()
            // Mark photos the NAS already has (e.g. uploaded via the Mac) before deciding what to upload
            if isConnectedToNAS {
                await NASReconciler.shared.reconcileIfDue()
            }
            await requestAutomaticSync()
        }
    }
    
    public func libraryDidChange() {
        Task {
            await requestAutomaticSync()
        }
    }
    
    // MARK: - Queue & run lifecycle
    
    private func enqueue(_ ids: [String], trigger: Trigger) {
        if runTask != nil && abortRequested {
            let pending = Set(deferredIds)
            deferredIds.append(contentsOf: ids.filter { !pending.contains($0) })
            deferredManual = deferredManual || trigger == .manual
            return
        }
        let fresh = ids.filter { !queued.contains($0) }
        guard !fresh.isEmpty else { return }
        queue.append(contentsOf: fresh)
        queued.formUnion(fresh)
        if runTask == nil {
            runIsManual = trigger == .manual
            syncedCount = 0
            totalToSyncCount = fresh.count
            currentProgress = 0
            start()
        } else {
            // New work revives a run that was only asked to wind down (background time expiry).
            stopRequested = false
            runIsManual = runIsManual || trigger == .manual
            totalToSyncCount += fresh.count
        }
    }
    
    private func dropQueue() {
        queue.removeAll()
        queued.removeAll()
    }
    
    private func start() {
        stopRequested = false
        abortRequested = false
        committedInRun = 0
        statusMessage = nil
        isSyncing = true
        beginBackgroundExecution()
        runTask = Task { [weak self] in
            await self?.runLoop()
            self?.finishRun()
        }
    }
    
    private func finishRun() {
        dropQueue()
        runTask = nil
        isSyncing = false
        currentItemName = ""
        if committedInRun > 0 {
            SynapsConfig.update { $0.lastSyncTimestamp = Date() }
        }
        endBackgroundExecution()
        let waiters = idleWaiters.values
        idleWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        if !deferredIds.isEmpty {
            let ids = deferredIds
            let manual = deferredManual
            deferredIds = []
            deferredManual = false
            enqueue(ids, trigger: manual ? .manual : .automatic)
        }
    }
    
    private func waitForIdle() async {
        guard runTask != nil else { return }
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if runTask == nil {
                    continuation.resume()
                } else {
                    idleWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.idleWaiters.removeValue(forKey: id)?.resume()
            }
        }
    }
    
    private func beginBackgroundExecution() {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "SynapsSync") { [weak self] in
            // Out of background time. Uploads already handed to the background URLSession continue.
            MainActor.assumeIsolated {
                self?.stopRequested = true
                self?.endBackgroundExecution()
            }
        }
    }
    
    private func endBackgroundExecution() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        backgroundTaskId = .invalid
    }
    
    private func automaticSyncBlocker() async -> String? {
        let cfg = SynapsConfig.load()
        guard cfg.autoSyncOnWifi else { return "Auto-Upload is off" }
        let network = await NetworkMonitor.shared.snapshot()
        guard network.isUnmeteredLAN else { return "waiting for Wi-Fi" }
        if cfg.requireCharging {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let state = UIDevice.current.batteryState
            guard state == .charging || state == .full else { return "waiting for charger" }
        }
        return nil
    }
    
    private func runLoop() async {
        currentItemName = "Connecting to NAS..."
        let online = await NASClient.shared.checkHealth()
        isConnectedToNAS = online
        guard online else {
            let message = "Cannot reach the NAS at \(NASClient.shared.getBaseUrl())"
            statusMessage = message
            if runIsManual {
                LocalCacheStore.shared.logActivity(eventType: .failed, filePath: "", filename: "Sync Failed", details: message, sourceId: SynapsConfig.load().sourceId)
            }
            return
        }
        
        while !queue.isEmpty && !stopRequested && !abortRequested && !Task.isCancelled {
            if !runIsManual, let reason = await automaticSyncBlocker() {
                statusMessage = "Paused: \(reason)"
                break
            }
            let cfg = SynapsConfig.load()
            let policy = PartPolicy(config: cfg)
            guard let window = await nextWindow(policy: policy) else { continue }
            await process(window: window, cfg: cfg, policy: policy)
        }
    }
    
    // MARK: - Windows
    
    private struct WindowAsset {
        let item: SynapsMediaItem
        var pending: [AssetPart]
        let primaryPath: String
    }
    
    /// Per-window bookkeeping, mutated only on the main actor.
    private final class WindowState {
        var remaining: [String: Set<AssetPartKind>] = [:]
        var uploadedBytes: [String: Int64] = [:]
        var uploadedFiles: [String: Int] = [:]
        var dedupFiles: [String: Int] = [:]
        var errors: [String: String] = [:]
        var finalized: Set<String> = []
    }
    
    /// Takes the next assets off the queue: at most `maxPartsPerWindow` pending parts and a
    /// staging budget of bytes (a single larger asset gets a window of its own).
    private func nextWindow(policy: PartPolicy) async -> [WindowAsset]? {
        let candidateIds = Array(queue.prefix(100))
        let partsById = await PhotoLibraryService.shared.ensureParts(for: candidateIds, policy: policy)
        if Task.isCancelled || abortRequested || stopRequested {
            return nil
        }
        let budget = Self.stagingBudget()
        var window: [WindowAsset] = []
        var partCount = 0
        var bytes: Int64 = 0
        var taken: [String] = []
        for id in candidateIds {
            let parts = partsById[id] ?? []
            let pending = policy.expectedParts(parts).filter { !$0.isCommitted }
            let pendingBytes = pending.reduce(Int64(0)) { $0 + $1.size }
            if !window.isEmpty && (partCount + pending.count > Self.maxPartsPerWindow || bytes + pendingBytes > budget) {
                break
            }
            taken.append(id)
            guard let item = PhotoLibraryService.shared.item(withId: id),
                  PhotoLibraryService.shared.assetIndex.asset(for: id) != nil else {
                bumpProgress() // deleted from the library meanwhile
                continue
            }
            guard !parts.isEmpty else {
                let message = "No exportable photo/video resource found for this item"
                LocalCacheStore.shared.recordAttempt(assetId: id, policy: policy, error: message)
                LocalCacheStore.shared.logActivity(eventType: .failed, filePath: item.originalPath, filename: item.filename, details: message, sourceId: SynapsConfig.load().sourceId)
                PhotoLibraryService.shared.refreshItems([id])
                bumpProgress()
                continue
            }
            if pending.isEmpty {
                // Already fully on the NAS (e.g. queued twice): just make sure the status shows it.
                LocalCacheStore.shared.recordAttempt(assetId: id, policy: policy, error: nil)
                PhotoLibraryService.shared.refreshItems([id])
                committedInRun += 1
                bumpProgress()
                continue
            }
            let primary = parts.first(where: { $0.isPrimary })
            window.append(WindowAsset(item: item, pending: pending, primaryPath: primary?.originalPath ?? item.originalPath))
            partCount += pending.count
            bytes += pendingBytes
        }
        queue.removeFirst(min(taken.count, queue.count))
        queued.subtract(taken)
        return window.isEmpty ? nil : window
    }
    
    /// Bytes of exported files that may sit in staging at once: ≤1 GB and ≤25% of free space.
    private static func stagingBudget() -> Int64 {
        let free = AssetExporter.availableDiskSpace()
        return max(64 * 1024 * 1024, min(1024 * 1024 * 1024, free / 4))
    }
    
    private func process(window: [WindowAsset], cfg: SynapsConfig, policy: PartPolicy) async {
        let ids = window.map { $0.item.id }
        let library = PhotoLibraryService.shared
        library.setSyncing(ids, active: true)
        let state = WindowState()
        for asset in window {
            state.remaining[asset.item.id] = Set(asset.pending.map { $0.kind })
        }
        var staged: [String: AssetExporter.ExportedFile] = [:] // key: assetId|kind
        let allowsExpensive = runIsManual
        let index = library.assetIndex
        
        func key(_ part: AssetPart) -> String { "\(part.assetId)|\(part.kind.rawValue)" }
        
        // A. Export + hash parts without a cached hash. Files are kept for phase C.
        var hashed: [(WindowAsset, AssetPart)] = []
        for asset in window {
            for var part in asset.pending {
                if stopRequested || abortRequested || Task.isCancelled { break }
                if state.errors[asset.item.id] != nil { break }
                if part.sha256 == nil {
                    currentItemName = "Reading \(part.filename)..."
                    do {
                        let file = try await AssetExporter.exportAndHash(
                            assetId: part.assetId, kind: part.kind, index: index,
                            progress: iCloudProgressReporter(filename: part.filename)
                        )
                        part.sha256 = file.sha256
                        part.size = file.size
                        staged[key(part)] = file
                        let (assetId, kind) = (part.assetId, part.kind)
                        let mtime = asset.item.modifiedAt.timeIntervalSince1970
                        await Task.detached(priority: .utility) {
                            LocalCacheStore.shared.setPartHash(assetId: assetId, kind: kind, sha256: file.sha256, size: file.size, hashMtime: mtime)
                        }.value
                    } catch {
                        if !(error is CancellationError) {
                            state.errors[asset.item.id] = "Couldn't read \(part.filename): \(error.localizedDescription)"
                        }
                        continue
                    }
                }
                hashed.append((asset, part))
            }
        }
        
        // B. Pre-check the whole window with the NAS: content it already has is linked instantly.
        var needUpload: [(WindowAsset, AssetPart)] = []
        var seenPaths = Set<String>()
        let checkable = hashed.filter { state.errors[$0.0.item.id] == nil && seenPaths.insert($0.1.originalPath).inserted }
        if !checkable.isEmpty && !abortRequested && !Task.isCancelled {
            currentItemName = "Checking \(checkable.count) file\(checkable.count == 1 ? "" : "s") with NAS..."
            let payloads = checkable.map { asset, part in
                IngestCheckFilePayload(
                    original_path: part.originalPath,
                    original_filename: part.filename,
                    file_size: part.size,
                    source_location: "Photos",
                    source_modified_at: NASClient.isoTimestamp(asset.item.modifiedAt),
                    client_sha256: part.sha256 ?? "",
                    is_favorite: asset.item.isFavorite
                )
            }
            do {
                let response = try await withRetries {
                    try await NASClient.shared.batchPreCheck(
                        sourceId: cfg.sourceId, friendlyName: cfg.friendlyName,
                        files: payloads, allowsExpensiveNetwork: allowsExpensive
                    )
                }
                let statusByPath = Dictionary(response.results.map { ($0.original_path, $0.status) }, uniquingKeysWith: { a, _ in a })
                var linked: [(assetId: String, kind: AssetPartKind, sha256: String)] = []
                for (asset, part) in checkable {
                    if statusByPath[part.originalPath] == "dedup_linked", let sha = part.sha256 {
                        linked.append((part.assetId, part.kind, sha))
                        AssetExporter.removeFile(staged.removeValue(forKey: key(part))?.url)
                    } else {
                        needUpload.append((asset, part))
                    }
                }
                let commits = linked
                await Task.detached(priority: .utility) {
                    LocalCacheStore.shared.markPartsCommitted(commits)
                }.value
                for ref in commits {
                    state.dedupFiles[ref.assetId, default: 0] += 1
                    partFinished(assetId: ref.assetId, kind: ref.kind, state: state, window: window, policy: policy, cfg: cfg)
                }
            } catch NASError.unauthorized {
                stopRun(because: NASError.unauthorized.localizedDescription, sourceId: cfg.sourceId)
            } catch {
                if !(error is CancellationError) {
                    stopRun(because: "NAS pre-check failed: \(error.localizedDescription)", sourceId: cfg.sourceId)
                }
            }
        }
        
        // C. Uploads. Files are exported (if not staged in A) one at a time while earlier ones
        //    upload; the background session caps concurrency at two connections.
        if !needUpload.isEmpty && !abortRequested && !Task.isCancelled {
            let watchdog = startConnectionWatchdog()
            await withTaskGroup(of: PartUploadResult.self) { group in
                var inFlight = 0
                for (asset, part) in needUpload {
                    // Keep a bounded number of uploads queued in the session (it opens at most two
                    // connections) and handle finished ones as we go: progress, failures, 401 abort.
                    while inFlight >= Self.maxQueuedUploads, let result = await group.next() {
                        inFlight -= 1
                        handle(result, state: state, window: window, policy: policy, cfg: cfg)
                    }
                    if abortRequested || Task.isCancelled { break }
                    if state.errors[asset.item.id] != nil { continue }
                    // Winding down (background time expired): still hand already-exported files to
                    // the background session (they upload while suspended), but don't export more.
                    if stopRequested && staged[key(part)] == nil { continue }
                    var file = staged.removeValue(forKey: key(part))
                    var sha = part.sha256 ?? ""
                    if file == nil {
                        currentItemName = "Reading \(part.filename)..."
                        do {
                            let fresh = try await AssetExporter.exportAndHash(
                                assetId: part.assetId, kind: part.kind, index: index,
                                progress: iCloudProgressReporter(filename: part.filename)
                            )
                            if fresh.sha256 != sha {
                                // Content differs from the cached hash: upload what we actually read.
                                sha = fresh.sha256
                                let mtime = asset.item.modifiedAt.timeIntervalSince1970
                                LocalCacheStore.shared.setPartHash(assetId: part.assetId, kind: part.kind, sha256: fresh.sha256, size: fresh.size, hashMtime: mtime)
                            }
                            file = fresh
                        } catch {
                            if !(error is CancellationError) {
                                state.errors[asset.item.id] = "Couldn't read \(part.filename): \(error.localizedDescription)"
                            }
                            continue
                        }
                    }
                    guard let file else { continue }
                    currentItemName = "Uploading \(part.filename)..."
                    let job = PartUploadJob(
                        part: part,
                        file: file,
                        sha256: sha,
                        fields: IngestUploadFields(
                            sourceId: cfg.sourceId,
                            originalPath: part.originalPath,
                            originalFilename: part.filename,
                            sourceLocation: "Photos",
                            clientSHA256: sha,
                            sourceCreatedAt: NASClient.isoTimestamp(asset.item.createdAt),
                            sourceModifiedAt: NASClient.isoTimestamp(asset.item.modifiedAt),
                            isFavorite: asset.item.isFavorite
                        ),
                        allowsExpensiveNetwork: allowsExpensive,
                        assetMtime: asset.item.modifiedAt.timeIntervalSince1970
                    )
                    group.addTask {
                        await Self.upload(job)
                    }
                    inFlight += 1
                }
                for await result in group {
                    handle(result, state: state, window: window, policy: policy, cfg: cfg)
                }
            }
            watchdog.cancel()
        }
        
        // Anything still staged was never handed to an upload (stopped / failed asset).
        for file in staged.values {
            AssetExporter.removeFile(file.url)
        }
        // Finalize assets that didn't complete (errors, stop, cancel).
        for asset in window where !state.finalized.contains(asset.item.id) {
            finalize(asset: asset, state: state, policy: policy, cfg: cfg)
        }
        library.setSyncing(ids, active: false)
    }
    
    private func handle(_ result: PartUploadResult, state: WindowState, window: [WindowAsset], policy: PartPolicy, cfg: SynapsConfig) {
        switch result.outcome {
        case .uploaded:
            state.uploadedFiles[result.assetId, default: 0] += 1
            state.uploadedBytes[result.assetId, default: 0] += result.bytes
            partFinished(assetId: result.assetId, kind: result.kind, state: state, window: window, policy: policy, cfg: cfg)
        case .unauthorized:
            if !abortRequested {
                stopRun(because: NASError.unauthorized.localizedDescription, sourceId: cfg.sourceId, cancelQueuedUploads: true)
            }
        case .failed(let message), .shaMismatch(let message):
            state.errors[result.assetId] = message
            if let asset = window.first(where: { $0.item.id == result.assetId }) {
                finalize(asset: asset, state: state, policy: policy, cfg: cfg)
            }
        case .stopRun(let message):
            state.errors[result.assetId] = message
            if !abortRequested {
                stopRun(because: message, sourceId: cfg.sourceId, cancelQueuedUploads: true)
            }
            if let asset = window.first(where: { $0.item.id == result.assetId }) {
                finalize(asset: asset, state: state, policy: policy, cfg: cfg)
            }
        case .cancelled:
            break
        }
    }
    
    private func partFinished(assetId: String, kind: AssetPartKind, state: WindowState, window: [WindowAsset], policy: PartPolicy, cfg: SynapsConfig) {
        state.remaining[assetId]?.remove(kind)
        if state.remaining[assetId]?.isEmpty == true, let asset = window.first(where: { $0.item.id == assetId }) {
            finalize(asset: asset, state: state, policy: policy, cfg: cfg)
        }
    }
    
    /// Records the asset's outcome once, logs it, and updates progress / the grid badge.
    private func finalize(asset: WindowAsset, state: WindowState, policy: PartPolicy, cfg: SynapsConfig) {
        let id = asset.item.id
        guard !state.finalized.contains(id) else { return }
        state.finalized.insert(id)
        let error = state.errors[id]
        let complete = state.remaining[id]?.isEmpty == true
        // Only a real error counts as a failed attempt; stopped/cancelled assets keep their status.
        let status = LocalCacheStore.shared.recordAttempt(assetId: id, policy: policy, error: error)
        
        if let error {
            LocalCacheStore.shared.logActivity(eventType: .failed, filePath: asset.primaryPath, filename: asset.item.filename, details: error, sourceId: cfg.sourceId)
        } else if complete && status == .committed {
            committedInRun += 1
            let uploaded = state.uploadedFiles[id] ?? 0
            let linked = state.dedupFiles[id] ?? 0
            if uploaded > 0 {
                let bytes = ByteCountFormatter.string(fromByteCount: state.uploadedBytes[id] ?? 0, countStyle: .file)
                var details = "Uploaded \(uploaded) file\(uploaded == 1 ? "" : "s") (\(bytes))"
                if linked > 0 {
                    details += ", \(linked) already on NAS"
                }
                LocalCacheStore.shared.logActivity(eventType: .uploaded, filePath: asset.primaryPath, filename: asset.item.filename, details: details, sourceId: cfg.sourceId)
            } else {
                LocalCacheStore.shared.logActivity(eventType: .dedupLinked, filePath: asset.primaryPath, filename: asset.item.filename, details: "Already on NAS: linked without uploading", sourceId: cfg.sourceId)
            }
        }
        PhotoLibraryService.shared.setSyncing([id], active: false)
        bumpProgress()
    }
    
    /// Ends the run after the current step and records why, once, in the activity log.
    /// `cancelQueuedUploads`: the NAS refuses everything right now (401, 507), so uploads already
    /// queued in the background session would only fail too.
    private func stopRun(because message: String, sourceId: String, cancelQueuedUploads: Bool = false) {
        statusMessage = message
        abortRequested = true
        LocalCacheStore.shared.logActivity(eventType: .failed, filePath: "", filename: "Sync Stopped", details: message, sourceId: sourceId)
        if cancelQueuedUploads {
            Task {
                await UploadSessionManager.shared.cancelAll()
            }
        }
    }
    
    private func bumpProgress() {
        syncedCount += 1
        currentProgress = Double(syncedCount) / Double(max(1, totalToSyncCount))
    }
    
    /// While uploads are outstanding and the app is in the foreground, re-checks the NAS when
    /// nothing has moved for a minute; after two failed probes the uploads are cancelled instead
    /// of waiting for the background session's long timeouts.
    private func startConnectionWatchdog() -> Task<Void, Never> {
        Task { [weak self] in
            var strikes = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard UIApplication.shared.applicationState == .active,
                      UploadSessionManager.shared.secondsSinceLastActivity > 60 else {
                    strikes = 0
                    continue
                }
                if await NASClient.shared.checkHealth() {
                    strikes = 0
                } else {
                    strikes += 1
                    if strikes >= 2 {
                        self.isConnectedToNAS = false
                        self.statusMessage = "Lost connection to the NAS"
                        self.abortRequested = true
                        await UploadSessionManager.shared.cancelAll()
                        return
                    }
                }
            }
        }
    }
    
    /// Retries transient failures (timeouts, connection drops, 5xx/429) with exponential backoff.
    private func withRetries<T: Sendable>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < Self.maxAttempts, NASClient.isTransient(error) else { throw error }
                try await Task.sleep(nanoseconds: Self.backoffNanos(attempt: attempt))
                attempt += 1
            }
        }
    }
    
    nonisolated private static func backoffNanos(attempt: Int) -> UInt64 {
        let base = min(30.0, 2.0 * pow(2.0, Double(attempt - 1))) // 2 s, 4 s, 8 s ... ≤30 s
        let jitter = Double.random(in: 0...0.5)
        return UInt64((base + jitter) * 1_000_000_000)
    }
    
    private func iCloudProgressReporter(filename: String) -> @Sendable (Double) -> Void {
        let throttle = ProgressThrottle()
        return { [weak self] value in
            guard throttle.shouldReport(value) else { return }
            let percent = Int(value * 100)
            Task { @MainActor in
                self?.currentItemName = "Downloading \(filename) from iCloud (\(percent)%)..."
            }
        }
    }
    
    // MARK: - Upload of one part (off the main actor)
    
    private struct PartUploadJob: Sendable {
        let part: AssetPart
        var file: AssetExporter.ExportedFile
        var sha256: String
        var fields: IngestUploadFields
        let allowsExpensiveNetwork: Bool
        let assetMtime: Double
    }
    
    private enum PartOutcome: Sendable {
        case uploaded
        case failed(String)
        case unauthorized
        case cancelled
        /// The NAS can't take more data right now (507 disk full): stop the whole run.
        case stopRun(String)
        /// 400 "SHA-256 mismatch": the bytes we sent don't match the hash we declared.
        case shaMismatch(String)
    }
    
    private struct PartUploadResult: Sendable {
        let assetId: String
        let kind: AssetPartKind
        let bytes: Int64
        let outcome: PartOutcome
    }
    
    nonisolated private static func upload(_ initialJob: PartUploadJob) async -> PartUploadResult {
        var job = initialJob
        var outcome = await uploadWithFallback(job)
        if case .shaMismatch = outcome {
            // The NAS hashed different bytes than we declared (file changed under us or got
            // corrupted on the way): re-read and re-hash once, then report if it still fails.
            AssetExporter.removeFile(job.file.url)
            do {
                let fresh = try await AssetExporter.exportAndHash(assetId: job.part.assetId, kind: job.part.kind, index: PhotoLibraryService.shared.assetIndex)
                LocalCacheStore.shared.setPartHash(assetId: job.part.assetId, kind: job.part.kind, sha256: fresh.sha256, size: fresh.size, hashMtime: job.assetMtime)
                job.file = fresh
                job.sha256 = fresh.sha256
                job.fields.clientSHA256 = fresh.sha256
                outcome = await uploadWithFallback(job)
                if case .shaMismatch(let detail) = outcome {
                    outcome = .failed("Upload of \(job.part.filename) failed twice with a SHA-256 mismatch: \(detail)")
                }
            } catch is CancellationError {
                outcome = .cancelled
            } catch {
                outcome = .failed("Couldn't re-read \(job.part.filename) after a SHA-256 mismatch: \(error.localizedDescription)")
            }
        }
        if case .uploaded = outcome {
            let ref = (job.part.assetId, job.part.kind, job.sha256)
            await Task.detached(priority: .utility) {
                LocalCacheStore.shared.markPartsCommitted([ref])
            }.value
        }
        AssetExporter.removeFile(job.file.url)
        return PartUploadResult(assetId: job.part.assetId, kind: job.part.kind, bytes: job.file.size, outcome: outcome)
    }
    
    nonisolated private static func uploadWithFallback(_ job: PartUploadJob) async -> PartOutcome {
        var attempt = 1
        while true {
            let useStream = !NASClient.shared.streamEndpointUnsupported
            var bodyURL: URL?
            let outcome: UploadOutcome
            do {
                var info = UploadTaskInfo(
                    assetId: job.part.assetId, kind: job.part.kind.rawValue, sha256: job.sha256,
                    size: job.file.size, filename: job.part.filename, originalPath: job.part.originalPath,
                    sourceId: job.fields.sourceId, endpoint: "stream", stagingFiles: [job.file.url.lastPathComponent]
                )
                if useStream {
                    let request = try NASClient.shared.streamUploadRequest(fields: job.fields, allowsExpensiveNetwork: job.allowsExpensiveNetwork)
                    outcome = await UploadSessionManager.shared.upload(request: request, fileURL: job.file.url, info: info)
                } else {
                    let boundary = "SynapsBoundary-\(UUID().uuidString)"
                    let body = AssetExporter.makeStagingURL(pathExtension: "multipart")
                    bodyURL = body
                    let fields = job.fields
                    let source = job.file.url
                    try await AssetExporter.runDetached {
                        try NASClient.writeMultipartBody(fields: fields, fileURL: source, to: body, boundary: boundary)
                    }
                    info.endpoint = "multipart"
                    info.stagingFiles.append(body.lastPathComponent)
                    let request = try NASClient.shared.multipartUploadRequest(boundary: boundary, allowsExpensiveNetwork: job.allowsExpensiveNetwork)
                    outcome = await UploadSessionManager.shared.upload(request: request, fileURL: body, info: info)
                }
            } catch is CancellationError {
                AssetExporter.removeFile(bodyURL)
                return .cancelled
            } catch {
                AssetExporter.removeFile(bodyURL)
                return .failed("Upload of \(job.part.filename) failed: \(error.localizedDescription)")
            }
            AssetExporter.removeFile(bodyURL)
            
            let retryable: Bool
            let message: String
            switch outcome {
            case .success:
                return .uploaded
            case .cancelled:
                return .cancelled
            case .httpError(let status, let detail):
                // 401 is an auth problem, never a reason to switch endpoints.
                if status == 401 {
                    return .unauthorized
                }
                if useStream && (status == 404 || status == 405 || status == 411) {
                    // Server predates PUT /api/v2/ingest/stream (404/405), or something in between
                    // dropped Content-Length (411): use multipart for the rest of the session.
                    NASClient.shared.streamEndpointUnsupported = true
                    continue
                }
                if status == 507 {
                    return .stopRun("The NAS disk is full (507). Free up space on the NAS, then sync again.")
                }
                let lowered = (detail ?? "").lowercased()
                if status == 400 && lowered.contains("mismatch") {
                    return .shaMismatch(detail ?? "SHA-256 mismatch")
                }
                let error = NASError.http(status: status, detail: detail)
                // A body cut short ("Incomplete upload", client disconnect) is worth another try.
                retryable = error.isTransient || (status == 400 && (lowered.contains("incomplete") || lowered.contains("disconnect")))
                message = error.localizedDescription
            case .transportError(let code, let text):
                retryable = NASClient.isTransient(URLError(URLError.Code(rawValue: code)))
                message = text
            }
            guard retryable, attempt < maxAttempts else {
                return .failed("Upload of \(job.part.filename) failed: \(message)")
            }
            do {
                try await Task.sleep(nanoseconds: backoffNanos(attempt: attempt))
            } catch {
                return .cancelled
            }
            attempt += 1
        }
    }
}

/// Rate-limits iCloud download progress updates to whole 5% steps.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStep = -1
    
    func shouldReport(_ value: Double) -> Bool {
        let step = Int(value * 20)
        lock.lock()
        defer { lock.unlock() }
        guard step != lastStep else { return false }
        lastStep = step
        return true
    }
}

/// Applies upload results that arrive with no sync run waiting for them (the app was relaunched
/// by the system for background-session events, or the run was stopped meanwhile).
enum SyncResultRecorder {
    static func applyDetachedUploadResult(info: UploadTaskInfo, outcome: UploadOutcome) {
        defer {
            for name in info.stagingFiles {
                AssetExporter.removeFile(AssetExporter.uploadsDirectory.appendingPathComponent(name))
            }
        }
        guard let kind = AssetPartKind(rawValue: info.kind) else { return }
        let store = LocalCacheStore.shared
        let policy = PartPolicy(config: SynapsConfig.load())
        switch outcome {
        case .success:
            store.markPartsCommitted([(info.assetId, kind, info.sha256)])
            if store.recordAttempt(assetId: info.assetId, policy: policy, error: nil) == .committed {
                store.logActivity(eventType: .uploaded, filePath: info.originalPath, filename: info.filename,
                                  details: "Uploaded in background (\(ByteCountFormatter.string(fromByteCount: info.size, countStyle: .file)))",
                                  sourceId: info.sourceId)
            }
        case .cancelled:
            return // user cancel or force-quit: leave the asset as it was
        case .httpError(let status, let detail):
            let error: NASError = status == 401 ? .unauthorized : .http(status: status, detail: detail)
            let message = error.localizedDescription
            store.recordAttempt(assetId: info.assetId, policy: policy, error: message)
            store.logActivity(eventType: .failed, filePath: info.originalPath, filename: info.filename, details: message, sourceId: info.sourceId)
        case .transportError(_, let message):
            store.recordAttempt(assetId: info.assetId, policy: policy, error: message)
            store.logActivity(eventType: .failed, filePath: info.originalPath, filename: info.filename, details: message, sourceId: info.sourceId)
        }
        let assetId = info.assetId
        Task { @MainActor in
            PhotoLibraryService.shared.refreshItems([assetId])
        }
    }
}
