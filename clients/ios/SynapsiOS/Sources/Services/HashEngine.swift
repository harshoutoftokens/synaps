import Foundation
import CryptoKit
import Photos

public final class HashEngine: Sendable {
    public static let shared = HashEngine()
    
    private init() {}
    
    /// Computes SHA-256 of file at given URL using streaming chunks to keep memory usage constant.
    public func computeSHA256(for fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        let bufferSize = 1024 * 1024 // 1 MB
        
        while true {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Computes SHA-256 for a PHAsset using PHAssetResourceManager streaming data.
    public func computeSHA256(for asset: PHAsset) async throws -> String {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let primaryResource = resources.first(where: {
            $0.type == .photo || $0.type == .video || $0.type == .pairedVideo || $0.type == .fullSizePhoto
        }) ?? resources.first else {
            throw NSError(domain: "HashEngine", code: 404, userInfo: [NSLocalizedDescriptionKey: "No suitable resource found for asset"])
        }
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempFile = tempDir.appendingPathComponent("synaps_hash_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempFile) }
        
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: primaryResource, toFile: tempFile, options: options) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        
        return try computeSHA256(for: tempFile)
    }
}
