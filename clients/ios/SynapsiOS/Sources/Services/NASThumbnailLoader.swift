import Foundation
import UIKit
import CryptoKit

/// Loads WebP thumbnails from GET /api/finder/thumbnail.
/// - Sends the API token (AsyncImage can't set headers).
/// - 202 {"status":"queued"} means the NAS is generating it: poll again after Retry-After, a
///   bounded number of times. 404/400/403/401 stop immediately.
/// - Only real 200 image bodies are cached (bounded memory + Caches/ on disk). Entries older
///   than the server's max-age (7 days) are revalidated with If-None-Match (304 = still valid).
/// - The caller's task cancellation (row scrolled away) cancels the request and the polling.
public final class NASThumbnailLoader: @unchecked Sendable {
    public static let shared = NASThumbnailLoader()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let diskDirectory: URL
    private let session: URLSession
    private static let maxQueuedPolls = 5
    private static let maxAge: TimeInterval = 7 * 24 * 3600 // Cache-Control: max-age=604800
    
    private init() {
        memoryCache.countLimit = 400
        memoryCache.totalCostLimit = 48 * 1024 * 1024
        
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        diskDirectory = caches.appendingPathComponent("nas_thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 3 // the NAS has one thumbnail worker; don't flood it
        config.timeoutIntervalForRequest = 15
        config.urlCache = nil                    // we keep our own cache of 200 responses only
        session = URLSession(configuration: config)
    }
    
    private func cacheKey(for path: String) -> String {
        let digest = Insecure.MD5.hash(data: Data((NASClient.shared.getBaseUrl() + "|" + path).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
    
    /// Memory-cache hit only (synchronous, for first render without flicker).
    public func cachedImage(for path: String) -> UIImage? {
        memoryCache.object(forKey: cacheKey(for: path) as NSString)
    }
    
    private struct DiskEntry: Sendable {
        let image: UIImage
        let etag: String?
        let isFresh: Bool
    }
    
    public func image(for path: String) async -> UIImage? {
        let key = cacheKey(for: path)
        if let hit = memoryCache.object(forKey: key as NSString) {
            return hit
        }
        let imageURL = diskDirectory.appendingPathComponent(key)
        let etagURL = diskDirectory.appendingPathComponent(key + ".etag")
        let disk = await Task.detached(priority: .userInitiated) { () -> DiskEntry? in
            guard let data = try? Data(contentsOf: imageURL),
                  let image = UIImage(data: data)?.preparingForDisplay() else { return nil }
            let modified = (try? imageURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let etag = try? String(contentsOf: etagURL, encoding: .utf8)
            return DiskEntry(image: image, etag: etag, isFresh: Date().timeIntervalSince(modified) < Self.maxAge)
        }.value
        if let disk, disk.isFresh {
            store(disk.image, key: key)
            return disk.image
        }
        
        var polls = 0
        while !Task.isCancelled {
            guard var request = try? NASClient.shared.thumbnailRequest(for: path) else { return disk?.image }
            if let etag = disk?.etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                return disk?.image // offline or cancelled: a stale thumbnail beats a placeholder
            }
            guard let http = response as? HTTPURLResponse else { return disk?.image }
            switch http.statusCode {
            case 200:
                guard let image = UIImage(data: data)?.preparingForDisplay() else { return disk?.image }
                store(image, key: key)
                try? data.write(to: imageURL, options: .atomic)
                if let etag = http.value(forHTTPHeaderField: "ETag") {
                    try? etag.write(to: etagURL, atomically: true, encoding: .utf8)
                } else {
                    try? FileManager.default.removeItem(at: etagURL)
                }
                return image
            case 304:
                guard let disk else { return nil }
                // Still valid: restart the max-age clock.
                try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: imageURL.path)
                store(disk.image, key: key)
                return disk.image
            case 202 where polls < Self.maxQueuedPolls:
                polls += 1
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 2
                do {
                    try await Task.sleep(nanoseconds: UInt64(min(max(retryAfter, 0.5), 10) * 1_000_000_000))
                } catch {
                    return nil
                }
            default:
                // 404 (no thumbnail: missing, unsupported or recently failed), 400/403 (bad
                // path), 401 (token), or still queued after the poll budget: stop.
                return disk?.image
            }
        }
        return nil
    }
    
    private func store(_ image: UIImage, key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
    }
}
