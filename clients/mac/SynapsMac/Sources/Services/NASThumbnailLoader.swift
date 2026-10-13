import Foundation
import AppKit
import CryptoKit
import ImageIO

/// Low-power, memory-safe thumbnail loader for NAS files.
/// 1. Strict 50 MB bounded memory cache to avoid Mac memory pressure.
/// 2. Local SSD disk cache (zero network calls on repeated viewing), trimmed to a size cap.
/// 3. Throttled URLSession (max 3 concurrent connections) to protect Core 2 Duo NAS.
/// 4. Duplicate requests for a path share one download; a cell scrolling away cancels its request.
public final class NASThumbnailLoader: @unchecked Sendable {
    public static let shared = NASThumbnailLoader()
    
    // Strict 50 MB bounded memory cache
    private let memoryCache = NSCache<NSString, NSImage>()
    
    // Local SSD disk cache directory
    private let diskCacheURL: URL
    /// Once the disk cache exceeds the limit it is trimmed (least recently used first) to the target.
    private let diskCacheLimit: Int64 = 512 * 1024 * 1024
    private let diskCacheTrimTarget: Int64 = 384 * 1024 * 1024
    
    // Throttled URLSession: max 3 concurrent connections to protect Core 2 Duo NAS
    private let session: URLSession
    /// Disk reads + decodes, a few at a time (a GCD concurrent queue would spawn a thread per cell).
    private let ioQueue = OperationQueue()
    
    /// 202 "queued" responses are polled with backoff for roughly a minute and a half.
    private static let maxPollAttempts = 12
    
    private let lock = NSLock()
    private var inFlight: [String: InFlightLoad] = [:]
    /// Paths the NAS answered 400/403/404 for (bad path, unsupported, or generation failed recently),
    /// so scrolling doesn't re-ask; entries expire so a long-running app eventually retries.
    private var unavailableUntil: [String: Date] = [:]
    private static let unavailableTTL: TimeInterval = 30 * 60
    
    /// Only read or mutated while holding `lock`.
    private final class InFlightLoad: @unchecked Sendable {
        var waiters: [UUID: (NSImage?) -> Void] = [:]
        var task: URLSessionDataTask?
        var pollWork: DispatchWorkItem?
    }
    
    private init() {
        memoryCache.countLimit = 300
        memoryCache.totalCostLimit = 50 * 1024 * 1024 // 50 MB RAM cap
        
        let cachesDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        self.diskCacheURL = cachesDir.appendingPathComponent("com.synaps.mac/nas_thumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)
        
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 3
        config.timeoutIntervalForRequest = 10.0
        config.timeoutIntervalForResource = 25.0
        // Our own disk cache already keeps every thumbnail; URLCache would store them twice.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
        
        ioQueue.name = "com.synaps.nasthumbnails.io"
        ioQueue.maxConcurrentOperationCount = 4
        ioQueue.qualityOfService = .userInitiated
        
        trimDiskCacheInBackground()
    }
    
    private static func cleanPath(_ relativePath: String) -> String {
        return relativePath.replacingOccurrences(of: "nas://", with: "")
    }
    
    /// Synchronous memory-cache check to avoid cell flicker on reload. Memory only: reading and
    /// decoding from disk here used to block the main thread for every cell that appeared.
    public func getCachedThumbnail(for relativePath: String) -> NSImage? {
        return memoryCache.object(forKey: Self.cleanPath(relativePath) as NSString)
    }
    
    /// Loads a thumbnail with multi-tier caching (Memory -> Disk -> NAS). The completion runs on the
    /// main queue. Returns a token for `cancelLoad(token:for:)`, or nil if it completed immediately.
    @discardableResult
    public func loadThumbnail(
        for relativePath: String,
        baseUrl: String,
        targetSize: CGFloat = 200,
        completion: @escaping (NSImage?) -> Void
    ) -> UUID? {
        let cleanPath = Self.cleanPath(relativePath)
        
        // 1. Tier 1: Check Memory Cache
        if let mem = memoryCache.object(forKey: cleanPath as NSString) {
            completion(mem)
            return nil
        }
        
        let token = UUID()
        lock.lock()
        if let until = unavailableUntil[cleanPath] {
            if until > Date() {
                lock.unlock()
                completion(nil)
                return nil
            }
            unavailableUntil[cleanPath] = nil
        }
        if let existing = inFlight[cleanPath] {
            // Coalesce with the request already running for this path
            existing.waiters[token] = completion
            lock.unlock()
            return token
        }
        let load = InFlightLoad()
        load.waiters[token] = completion
        inFlight[cleanPath] = load
        lock.unlock()
        
        // 2. Tier 2: Check Local SSD Disk Cache in background
        ioQueue.addOperation { [weak self] in
            guard let self = self, self.isWanted(cleanPath, load) else { return }
            if let img = self.loadFromDisk(cleanPath) {
                self.memoryCache.setObject(img, forKey: cleanPath as NSString, cost: Self.cost(of: img))
                self.deliver(cleanPath, load: load, image: img)
                return
            }
            
            // 3. Tier 3: Network Fetch from NAS with concurrency throttling
            self.fetchFromNAS(cleanPath: cleanPath, baseUrl: baseUrl, load: load, attempt: 0)
        }
        return token
    }
    
    /// Drops one cell's interest; the download is cancelled once nobody is waiting for it.
    public func cancelLoad(token: UUID, for relativePath: String) {
        let cleanPath = Self.cleanPath(relativePath)
        lock.lock()
        guard let load = inFlight[cleanPath] else {
            lock.unlock()
            return
        }
        load.waiters[token] = nil
        let abandoned = load.waiters.isEmpty
        if abandoned {
            inFlight[cleanPath] = nil
        }
        lock.unlock()
        if abandoned {
            load.task?.cancel()
            load.pollWork?.cancel()
        }
    }
    
    /// Cancels every pending request for a path (all waiters).
    public func cancelLoad(for relativePath: String) {
        let cleanPath = Self.cleanPath(relativePath)
        lock.lock()
        let load = inFlight.removeValue(forKey: cleanPath)
        lock.unlock()
        load?.task?.cancel()
        load?.pollWork?.cancel()
    }
    
    private func isWanted(_ cleanPath: String, _ load: InFlightLoad) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inFlight[cleanPath] === load && !load.waiters.isEmpty
    }
    
    private func deliver(_ cleanPath: String, load: InFlightLoad, image: NSImage?) {
        lock.lock()
        guard inFlight[cleanPath] === load else {
            lock.unlock()
            return
        }
        inFlight[cleanPath] = nil
        let waiters = Array(load.waiters.values)
        lock.unlock()
        DispatchQueue.main.async {
            waiters.forEach { $0(image) }
        }
    }
    
    private func fetchFromNAS(cleanPath: String, baseUrl: String, load: InFlightLoad, attempt: Int) {
        guard isWanted(cleanPath, load) else { return }
        
        let request: URLRequest
        do {
            request = try NASClient.shared.makeRequest(
                path: "/api/finder/thumbnail",
                queryItems: [URLQueryItem(name: "path", value: cleanPath)],
                baseUrl: baseUrl,
                timeout: 10.0
            )
        } catch {
            deliver(cleanPath, load: load, image: nil)
            return
        }
        
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            if (error as? URLError)?.code == .cancelled || !self.isWanted(cleanPath, load) {
                return
            }
            
            if let http = response as? HTTPURLResponse {
                switch http.statusCode {
                case 200:
                    if let data = data, let img = Self.decode(data) {
                        // Write to local SSD disk cache
                        try? data.write(to: self.diskCacheURLFor(cleanPath: cleanPath), options: .atomic)
                        // Put in bounded RAM cache
                        self.memoryCache.setObject(img, forKey: cleanPath as NSString, cost: Self.cost(of: img))
                        self.deliver(cleanPath, load: load, image: img)
                        return
                    }
                case 202 where attempt < Self.maxPollAttempts:
                    // Queued on the NAS's single background worker: back off (2s, 3s, 4.5s, ... ≤10s)
                    // instead of polling every cell at a fixed rate.
                    let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 0
                    let delay = max(retryAfter, min(10.0, 2.0 * pow(1.5, Double(attempt))))
                    self.schedulePoll(cleanPath: cleanPath, baseUrl: baseUrl, load: load, attempt: attempt + 1, after: delay)
                    return
                case 401:
                    NASClient.shared.reportUnauthorized()
                case 400, 403, 404:
                    self.lock.lock()
                    self.unavailableUntil[cleanPath] = Date().addingTimeInterval(Self.unavailableTTL)
                    self.lock.unlock()
                default:
                    break
                }
            }
            
            self.deliver(cleanPath, load: load, image: nil)
        }
        
        lock.lock()
        guard inFlight[cleanPath] === load else {
            lock.unlock()
            return
        }
        load.task = task
        load.pollWork = nil
        lock.unlock()
        task.resume()
    }
    
    private func schedulePoll(cleanPath: String, baseUrl: String, load: InFlightLoad, attempt: Int, after delay: Double) {
        let work = DispatchWorkItem { [weak self] in
            self?.fetchFromNAS(cleanPath: cleanPath, baseUrl: baseUrl, load: load, attempt: attempt)
        }
        lock.lock()
        guard inFlight[cleanPath] === load else {
            lock.unlock()
            return
        }
        load.task = nil
        load.pollWork = work
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
    }
    
    // MARK: - Decoding & disk cache
    
    /// Decodes on the calling (background) thread; NSImage(data:) would defer it to the first draw
    /// on the main thread.
    private static func decode(_ data: Data) -> NSImage? {
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        if let source = CGImageSourceCreateWithData(data as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, options) {
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }
        return NSImage(data: data)
    }
    
    private static func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return Int(image.size.width * image.size.height * 4)
    }
    
    private func loadFromDisk(_ cleanPath: String) -> NSImage? {
        let url = diskCacheURLFor(cleanPath: cleanPath)
        guard let data = try? Data(contentsOf: url), let img = Self.decode(data) else { return nil }
        // Touch it so trimming evicts the least recently viewed thumbnails first
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return img
    }
    
    private func diskCacheURLFor(cleanPath: String) -> URL {
        let hash = Insecure.MD5.hash(data: Data(cleanPath.utf8))
        let hex = hash.map { String(format: "%02hhx", $0) }.joined()
        return diskCacheURL.appendingPathComponent("\(hex).webp")
    }
    
    /// The disk cache used to grow forever; trim it once per launch in the background.
    private func trimDiskCacheInBackground() {
        let directory = diskCacheURL
        let limit = diskCacheLimit
        let target = diskCacheTrimTarget
        DispatchQueue.global(qos: .background).async {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey, .fileSizeKey]
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            ) else { return }
            
            var entries: [(url: URL, date: Date, size: Int64)] = []
            var total: Int64 = 0
            for url in files {
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
                total += size
                entries.append((url, values.contentModificationDate ?? .distantPast, size))
            }
            guard total > limit else { return }
            
            for entry in entries.sorted(by: { $0.date < $1.date }) {
                guard total > target else { break }
                if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                    total -= entry.size
                }
            }
        }
    }
}
