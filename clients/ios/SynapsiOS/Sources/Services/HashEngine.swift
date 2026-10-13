import Foundation
import CryptoKit

public final class HashEngine: Sendable {
    public static let shared = HashEngine()
    
    /// 4 MB reads: large enough to amortize syscalls, small enough to keep memory flat.
    public static let chunkSize = 4 * 1024 * 1024
    
    private init() {}
    
    /// Computes the SHA-256 of a file with incremental CryptoKit hashing so memory use stays
    /// constant regardless of file size. Throws CancellationError if the calling task is cancelled.
    public func computeSHA256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            // autoreleasepool: FileHandle hands back bridged NSData that would otherwise pile
            // up until the loop exits (GBs for a long 4K video).
            let done: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty else {
                    return true
                }
                hasher.update(data: chunk)
                return false
            }
            if done { break }
        }
        return Self.hexString(hasher.finalize())
    }
    
    static func hexString(_ digest: SHA256.Digest) -> String {
        let hexDigits = Array("0123456789abcdef".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            bytes.append(hexDigits[Int(byte >> 4)])
            bytes.append(hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
