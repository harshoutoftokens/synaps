import Foundation
import AppKit
import CryptoKit

/// Low-power, memory-safe thumbnail loader for NAS files.
/// 1. Strict 50 MB bounded memory cache to avoid Mac memory pressure.
/// 2. Permanent local SSD disk cache (zero network calls on repeated viewing).
/// 3. Throttled URLSession (max 3 concurrent connections) to protect Core 2 Duo NAS.
/// 4. Cancellation support for off-screen cells.
public final class NASThumbnailLoader {
    public static let shared = NASThumbnailLoader()
    
    // Strict 50 MB bounded memory cache
    private let memoryCache = NSCache<NSString, NSImage>()
    
    // Local SSD disk cache directory
    private let diskCacheURL: URL
    
    // Throttled URLSession: max 3 concurrent connections to protect Core 2 Duo NAS
    private let session: URLSession
    
    // Active tasks map for cancellation on scroll-away
    private var activeTasks: [String: URLSessionDataTask] = [:]
    private var cancelledPaths = Set<String>()
    private let lock = NSLock()
    
    private init() {
        memoryCache.countLimit = 150
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB RAM cap
        
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.diskCacheURL = cachesDir.appendingPathComponent("com.synaps.mac/nas_thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 25.0
        config.requestCachePolicy = .useProtocolCachePolicy
        self.session = URLSession(configuration: config)
    }
    
    /// Synchronous memory / fast-disk check to avoid cell flicker on reload.
    public func getCachedThumbnail(for relativePath: String) -> NSImage? {
        let cleanPath = relativePath.replacingOccurrences(of: "nas://", with: "")
        let key = cleanPath as NSString
        if let mem = memoryCache.object(forKey: key) {
            return mem
        }
        
        let diskURL = diskCacheURLFor(relativePath: cleanPath)
        if FileManager.default.fileExists(atPath: diskURL.path),
           let data = try? Data(contentsOf: diskURL),
           let img = NSImage(data: data) {
            let cost = Int(img.size.width * img.size.height * 4)
            memoryCache.setObject(img, forKey: key, cost: cost)
            return img
        }
        
        return nil
    }
    
    /// Asynchronously loads thumbnail with multi-tier caching (Memory -> Disk -> NAS).
    public func loadThumbnail(
        for relativePath: String,
        baseUrl: String,
        targetSize: CGFloat = 200,
        completion: @escaping (NSImage?) -> Void
    ) {
        let cleanPath = relativePath.replacingOccurrences(of: "nas://", with: "")
        let key = cleanPath as NSString
        
        lock.lock()
        cancelledPaths.remove(cleanPath)
        lock.unlock()
        
        // 1. Tier 1: Check Memory Cache
        if let mem = memoryCache.object(forKey: key) {
            completion(mem)
            return
        }
        
        // 2. Tier 2: Check Local SSD Disk Cache in background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let diskURL = self.diskCacheURLFor(relativePath: cleanPath)
            if FileManager.default.fileExists(atPath: diskURL.path),
               let data = try? Data(contentsOf: diskURL),
               let img = NSImage(data: data) {
                let cost = Int(img.size.width * img.size.height * 4)
                self.memoryCache.setObject(img, forKey: key, cost: cost)
                DispatchQueue.main.async {
                    completion(img)
                }
                return
            }
            
            // 3. Tier 3: Network Fetch from NAS with concurrency throttling
            self.fetchFromNAS(cleanPath: cleanPath, baseUrl: baseUrl, retryCount: 0, completion: completion)
        }
    }
    
    private func fetchFromNAS(
        cleanPath: String,
        baseUrl: String,
        retryCount: Int,
        completion: @escaping (NSImage?) -> Void
    ) {
        lock.lock()
        if cancelledPaths.contains(cleanPath) {
            lock.unlock()
            return
        }
        lock.unlock()
        
        var components = URLComponents(string: "\(baseUrl)/api/finder/thumbnail")
        components?.queryItems = [URLQueryItem(name: "path", value: cleanPath)]
        
        guard let url = components?.url else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = 10.0
        
        lock.lock()
        activeTasks[cleanPath]?.cancel()
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            
            self.lock.lock()
            self.activeTasks.removeValue(forKey: cleanPath)
            let isCancelled = self.cancelledPaths.contains(cleanPath)
            self.lock.unlock()
            
            if isCancelled || (error as? URLError)?.code == .cancelled {
                return
            }
            
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 200, let data = data, let img = NSImage(data: data) {
                    // Write to local SSD disk cache (async)
                    let diskURL = self.diskCacheURLFor(relativePath: cleanPath)
                    try? data.write(to: diskURL, options: .atomic)
                    
                    // Put in bounded RAM cache
                    let cost = Int(img.size.width * img.size.height * 4)
                    self.memoryCache.setObject(img, forKey: cleanPath as NSString, cost: cost)
                    
                    DispatchQueue.main.async {
                        completion(img)
                    }
                    return
                } else if http.statusCode == 202 && retryCount < 12 {
                    // Queued on NAS background worker; poll every 2.5s matching Web App behavior
                    let delay: Double = 2.5
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self else { return }
                        self.lock.lock()
                        let stillCancelled = self.cancelledPaths.contains(cleanPath)
                        self.lock.unlock()
                        if !stillCancelled {
                            self.fetchFromNAS(cleanPath: cleanPath, baseUrl: baseUrl, retryCount: retryCount + 1, completion: completion)
                        }
                    }
                    return
                }
            }
            
            DispatchQueue.main.async {
                completion(nil)
            }
        }
        
        activeTasks[cleanPath] = task
        lock.unlock()
        
        task.resume()
    }
    
    /// Cancels in-flight download task for an item when its view scrolls off-screen.
    public func cancelLoad(for relativePath: String) {
        let cleanPath = relativePath.replacingOccurrences(of: "nas://", with: "")
        lock.lock()
        cancelledPaths.insert(cleanPath)
        activeTasks[cleanPath]?.cancel()
        activeTasks.removeValue(forKey: cleanPath)
        lock.unlock()
    }
    
    private func diskCacheURLFor(relativePath: String) -> URL {
        let cleanPath = relativePath.replacingOccurrences(of: "nas://", with: "")
        let hash = Insecure.MD5.hash(data: Data(cleanPath.utf8))
        let hex = hash.map { String(format: "%02hhx", $0) }.joined()
        return diskCacheURL.appendingPathComponent("\(hex).webp")
    }
}
