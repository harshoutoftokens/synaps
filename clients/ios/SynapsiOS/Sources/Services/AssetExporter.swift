import Foundation
import Photos

/// Exports individual PhotoKit resources (original photo/video, Live Photo video, RAW companion,
/// edited render) to files and hashes them, without ever loading a whole file into memory.
public enum AssetExporter {
    public struct ExportedFile: Sendable {
        public let url: URL
        public let sha256: String
        public let size: Int64
    }
    
    public enum ExportError: LocalizedError {
        case assetMissing(String)
        case resourceMissing(String)
        case insufficientStorage(needed: Int64)
        
        public var errorDescription: String? {
            switch self {
            case .assetMissing:
                return "The photo is no longer in the library"
            case .resourceMissing(let kind):
                return "The \(kind) resource of this item is unavailable"
            case .insufficientStorage(let needed):
                return "Not enough free space on this iPhone to stage \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) for upload"
            }
        }
    }
    
    /// Staging area for exported files. Lives in Application Support rather than tmp/ because a
    /// background URLSession may still be reading a file after the app was suspended or killed,
    /// and tmp/ can be purged while the app isn't running. Excluded from iCloud/iTunes backup.
    public static let uploadsDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        var dir = base.appendingPathComponent("SynapsUploads", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? dir.setResourceValues(values)
        return dir
    }()
    
    public static func makeStagingURL(pathExtension: String) -> URL {
        let ext = pathExtension.isEmpty ? "tmp" : pathExtension
        return uploadsDirectory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }
    
    public static func removeFile(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    /// Bytes available for "important" (user-initiated) work on the data volume.
    public static func availableDiskSpace() -> Int64 {
        let values = try? uploadsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }
    
    /// Exports one resource of an asset and computes its SHA-256 in a streaming pass.
    /// The caller owns the returned file and must delete it.
    public static func exportAndHash(
        assetId: String,
        kind: AssetPartKind,
        index: AssetIndex,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> ExportedFile {
        guard let asset = index.asset(for: assetId) else {
            throw ExportError.assetMissing(assetId)
        }
        guard let resource = PHAssetResource.assetResources(for: asset).first(where: { $0.type == kind.resourceType }) else {
            throw ExportError.resourceMissing(kind.rawValue)
        }
        let expectedSize = PartScanner.fileSize(of: resource)
        // Leave headroom: the multipart fallback temporarily needs a second copy.
        if expectedSize > 0 && availableDiskSpace() < expectedSize * 2 + 200 * 1024 * 1024 {
            throw ExportError.insufficientStorage(needed: expectedSize)
        }
        
        let url = makeStagingURL(pathExtension: (resource.originalFilename as NSString).pathExtension)
        do {
            try await write(resource, to: url, progress: progress)
            let sha = try await runDetached {
                try HashEngine.shared.computeSHA256(for: url)
            }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? expectedSize
            return ExportedFile(url: url, sha256: sha, size: size)
        } catch {
            removeFile(url)
            throw error
        }
    }
    
    /// PHAssetResourceManager.writeData streams the resource straight to disk (downloading the
    /// original from iCloud when the library uses "Optimize iPhone Storage"). writeData itself
    /// can't be cancelled, so a cancelled caller is released immediately and the partial file is
    /// deleted once Photos finishes.
    private static func write(_ resource: PHAssetResource, to url: URL, progress: (@Sendable (Double) -> Void)?) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if let progress {
            options.progressHandler = { value in progress(value) }
        }
        let gate = ResumeGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                    if !gate.finish(error: error) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        } onCancel: {
            gate.cancel()
        }
    }
    
    /// Runs blocking work (hashing, file copies) off the cooperative pool's caller context while
    /// still propagating cancellation into it.
    public static func runDetached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) {
            try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
    
    /// Deletes staging files left behind by a crash or a killed process. Files referenced by
    /// in-flight background uploads (`keeping`) and files created by this process are kept.
    public static func cleanupStagingDirectory(keeping: Set<String>, createdBefore cutoff: Date) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: uploadsDirectory, includingPropertiesForKeys: keys) else { return }
        for file in files where !keeping.contains(file.lastPathComponent) {
            let created = (try? file.resourceValues(forKeys: Set(keys)))?.creationDate ?? .distantPast
            if created < cutoff {
                try? fm.removeItem(at: file)
            }
        }
        // v1 staged exports in tmp/ with these prefixes and could leak them on errors.
        let tmp = fm.temporaryDirectory
        if let leftovers = try? fm.contentsOfDirectory(atPath: tmp.path) {
            for name in leftovers where name.hasPrefix("synaps_export_") || name.hasPrefix("synaps_ios_upload_") || name.hasPrefix("synaps_hash_") {
                try? fm.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }
}

/// Resumes a continuation exactly once, either with the operation's result or with
/// CancellationError when the awaiting task is cancelled first.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false
    private var finished = false
    
    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        lock.unlock()
    }
    
    /// Returns false when the waiter had already been released by cancellation.
    @discardableResult
    func finish(error: Error?) -> Bool {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        finished = true
        let wasCancelled = cancelled
        let cont = continuation
        continuation = nil
        lock.unlock()
        if wasCancelled {
            return false
        }
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: ())
        }
        return true
    }
    
    func cancel() {
        lock.lock()
        guard !cancelled, !finished else {
            lock.unlock()
            return
        }
        cancelled = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: CancellationError())
    }
}
