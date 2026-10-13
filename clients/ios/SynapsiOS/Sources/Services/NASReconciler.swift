import Foundation

/// Marks photos the NAS already has as committed, without reading or uploading them.
///
/// The sync engine only learns that a photo is on the NAS after exporting and hashing it. Photos
/// that reached the NAS another way (AirDropped to the Mac and uploaded by the Mac app, an older
/// app install, the web uploader) would otherwise show as uncommitted until a full sync. This asks
/// the NAS which (file name, size) pairs it already holds — both are known from the photo library
/// index without touching the photo data — and marks those parts committed with the NAS's hash.
@MainActor
public final class NASReconciler: ObservableObject {
    public static let shared = NASReconciler()

    @Published public private(set) var isRunning = false
    /// Outcome of the last run, shown in Settings.
    @Published public private(set) var lastResult: String?

    /// Automatic runs (app becomes active) happen at most this often; Settings can run it any time.
    private static let automaticInterval: TimeInterval = 6 * 3600
    private static let lastRunKey = "nasReconcileLastRun"

    private init() {}

    /// Runs when the last run is older than `automaticInterval` (or never happened).
    public func reconcileIfDue() async {
        let last = UserDefaults.standard.double(forKey: Self.lastRunKey)
        guard Date().timeIntervalSince1970 - last >= Self.automaticInterval else { return }
        await reconcile()
    }

    /// Looks up every not-yet-committed part on the NAS. Returns the number of items that became committed.
    @discardableResult
    public func reconcile() async -> Int {
        guard !isRunning else { return 0 }
        isRunning = true
        defer { isRunning = false }

        let library = PhotoLibraryService.shared
        await library.ensureLoaded()
        guard library.isAuthorized else {
            lastResult = "Photo library access is needed to compare with the NAS."
            return 0
        }
        let policy = PartPolicy(config: SynapsConfig.load())
        let candidateIds = library.mediaItems.filter { $0.syncStatus != .committed }.map(\.id)
        guard !candidateIds.isEmpty else {
            finish("Everything is already marked as committed.")
            return 0
        }

        // File names and sizes come from the resource index (cheap, no photo data is read).
        var wanted: [IngestMatchFile: [(assetId: String, kind: AssetPartKind)]] = [:]
        var start = 0
        while start < candidateIds.count {
            let chunk = Array(candidateIds[start..<min(start + 400, candidateIds.count)])
            start += chunk.count
            let parts = await library.ensureParts(for: chunk, policy: policy)
            for part in parts.values.flatMap({ policy.expectedParts($0) }) where !part.isCommitted && part.size > 0 {
                wanted[IngestMatchFile(filename: part.filename, size: part.size), default: []].append((part.assetId, part.kind))
            }
        }

        var refs: [(assetId: String, kind: AssetPartKind, sha256: String)] = []
        let keys = Array(wanted.keys)
        do {
            var offset = 0
            while offset < keys.count {
                let batch = Array(keys[offset..<min(offset + NASClient.maxMatchBatchSize, keys.count)])
                offset += batch.count
                for match in try await NASClient.shared.matchExisting(batch) {
                    for target in wanted[IngestMatchFile(filename: match.filename, size: match.size)] ?? [] {
                        refs.append((target.assetId, target.kind, match.sha256))
                    }
                }
            }
        } catch NASError.http(status: 404, _) {
            lastResult = "The NAS is running an older version without this check. Update the NAS, then try again."
            return 0
        } catch {
            lastResult = "Couldn't reach the NAS: \(error.localizedDescription)"
            return 0
        }

        let found = refs
        let changed = await Task.detached(priority: .utility) {
            LocalCacheStore.shared.markPartsFoundOnNAS(found, policy: policy)
        }.value
        library.refreshItems(changed)

        // Items whose every expected part is now committed (an edit or Live Photo video may still be missing).
        let states = await Task.detached(priority: .utility) {
            LocalCacheStore.shared.getStates(assetIds: Array(changed))
        }.value
        let committed = states.values.filter { policy.status(for: $0.parts, lastAttemptFailed: false) == .committed }.count
        if committed > 0 {
            LocalCacheStore.shared.logActivity(
                eventType: .dedupLinked, filePath: "", filename: "\(committed) items",
                details: "Already on the NAS (matched by file name and size); marked committed without uploading",
                sourceId: SynapsConfig.load().sourceId
            )
        }
        let partial = changed.count - committed
        var message = committed == 1 ? "1 item was already on the NAS." : "\(committed) items were already on the NAS."
        if partial > 0 {
            message += " \(partial) more are partly there (an edited version or Live Photo video is still missing)."
        }
        finish(message)
        return committed
    }

    private func finish(_ message: String) {
        lastResult = message
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastRunKey)
    }
}
