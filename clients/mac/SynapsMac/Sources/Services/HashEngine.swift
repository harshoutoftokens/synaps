import Foundation
import CryptoKit

public enum HashEngine {
    public static func computeSHA256(for filePath: String, chunkSize: Int = 1024 * 1024) -> String? {
        guard let fileHandle = FileHandle(forReadingAtPath: filePath) else { return nil }
        defer { try? fileHandle.close() }
        
        var hasher = SHA256()
        while true {
            var shouldStop = false
            autoreleasepool {
                let data = fileHandle.readData(ofLength: chunkSize)
                if data.isEmpty {
                    shouldStop = true
                } else {
                    hasher.update(data: data)
                }
            }
            if shouldStop { break }
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
}
