import Foundation
import CryptoKit

public enum HashEngine {
    /// 4 MB reads keep memory bounded (one chunk per hasher) while amortizing syscall overhead.
    public static let defaultChunkSize = 4 * 1024 * 1024
    
    /// Parallel hashing helps on SSDs (SHA-256 is CPU-bound there) but thrashes spinning disks,
    /// so stay well below the core count.
    public static var defaultParallelism: Int {
        return max(1, min(ProcessInfo.processInfo.activeProcessorCount - 1, 4))
    }
    
    /// Blocking reads run here rather than on Swift's cooperative pool, which must stay free for
    /// URLSession completions and UI work.
    private static let hashQueue = DispatchQueue(label: "com.synaps.hashengine", qos: .utility, attributes: .concurrent)
    
    /// Streams the file through SHA-256. Returns nil if the file can't be read or if
    /// `shouldContinue` returns false (checked between chunks, so cancelling a 50 GB hash is quick).
    public static func computeSHA256(
        for filePath: String,
        chunkSize: Int = defaultChunkSize,
        shouldContinue: () -> Bool = { true }
    ) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        while true {
            guard shouldContinue() else { return nil }
            let chunk: Data?
            do {
                // The throwing API reports I/O errors instead of raising an ObjC exception.
                chunk = try autoreleasepool { try fileHandle.read(upToCount: chunkSize) }
            } catch {
                print("⚠️ [HashEngine] Read failed for \(filePath): \(error.localizedDescription)")
                return nil
            }
            guard let data = chunk, !data.isEmpty else { break }
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    public static func computeSHA256Async(for filePath: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let hash = computeSHA256(for: filePath)
                continuation.resume(returning: hash)
            }
        }
    }
    
    /// Hashes many files with bounded parallelism. Honors task cancellation (unfinished files are
    /// omitted). Returns path -> hex digest for every file that could be read.
    public static func computeSHA256s(
        for paths: [String],
        maxConcurrent: Int = defaultParallelism,
        onFileHashed: (@Sendable (String, String?) -> Void)? = nil
    ) async -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        return await withTaskGroup(of: (String, String?).self) { group in
            var results: [String: String] = [:]
            var iterator = paths.makeIterator()
            let width = max(1, maxConcurrent)
            
            func addNext() -> Bool {
                guard !Task.isCancelled, let path = iterator.next() else { return false }
                group.addTask {
                    let cancelled = CancellationFlag()
                    return await withTaskCancellationHandler {
                        await withCheckedContinuation { continuation in
                            hashQueue.async {
                                let sha = computeSHA256(for: path, shouldContinue: { !cancelled.isSet })
                                continuation.resume(returning: (path, sha))
                            }
                        }
                    } onCancel: {
                        cancelled.set()
                    }
                }
                return true
            }
            
            for _ in 0..<width {
                if !addNext() { break }
            }
            while let (path, sha) = await group.next() {
                if let sha = sha {
                    results[path] = sha
                }
                onFileHashed?(path, sha)
                _ = addNext()
            }
            return results
        }
    }
}

/// Lets a cancelled task stop a hash running on a GCD thread (which has no task to check).
private final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    
    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    
    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
