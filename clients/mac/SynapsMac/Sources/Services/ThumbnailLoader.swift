import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing

/// Thumbnails of local files. Work runs on a bounded queue (a grid of thousands of photos used to
/// spawn a thread per cell on a concurrent queue), duplicate requests for a path share one render,
/// and a cell scrolling away cancels its request.
public final class ThumbnailLoader: @unchecked Sendable {
    public static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var pending: [String: PendingLoad] = [:]
    
    /// `waiters` is only read or mutated while holding `lock`.
    private final class PendingLoad: @unchecked Sendable {
        let operation: BlockOperation
        var waiters: [UUID: (NSImage?) -> Void] = [:]
        
        init(operation: BlockOperation) {
            self.operation = operation
        }
    }
    
    private struct Rendered {
        let image: NSImage
        let cost: Int
        /// Icon fallbacks aren't cached so a later attempt can still produce a real thumbnail.
        let cacheable: Bool
    }
    
    /// Receives the QuickLook result on another thread.
    private final class RenderBox: @unchecked Sendable {
        var value: Rendered?
    }
    
    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 60 * 1024 * 1024 // Strict 60 MB maximum RAM limit!
        queue.name = "com.synaps.thumbnailqueue"
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
    }
    
    public func cachedThumbnail(for path: String) -> NSImage? {
        return cache.object(forKey: path as NSString)
    }
    
    /// `targetSize` is the longest edge in pixels. Returns a token for `cancelLoad(token:for:)`,
    /// or nil if the completion already ran (memory cache hit).
    @discardableResult
    public func loadThumbnail(for path: String, targetSize: CGFloat = 200, completion: @escaping (NSImage?) -> Void) -> UUID? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return nil
        }
        
        let token = UUID()
        lock.lock()
        if let existing = pending[path] {
            existing.waiters[token] = completion
            lock.unlock()
            return token
        }
        let operation = BlockOperation()
        let load = PendingLoad(operation: operation)
        load.waiters[token] = completion
        pending[path] = load
        lock.unlock()
        
        operation.addExecutionBlock { [weak self, unowned operation] in
            guard let self = self else { return }
            let rendered = operation.isCancelled ? nil : self.render(path: path, targetPixels: max(64, targetSize))
            if let rendered = rendered, rendered.cacheable {
                self.cache.setObject(rendered.image, forKey: path as NSString, cost: rendered.cost)
            }
            self.finish(path: path, load: load, image: rendered?.image)
        }
        queue.addOperation(operation)
        return token
    }
    
    /// Drops one cell's interest; the render is cancelled once nobody is waiting for it.
    public func cancelLoad(token: UUID, for path: String) {
        lock.lock()
        guard let load = pending[path] else {
            lock.unlock()
            return
        }
        load.waiters[token] = nil
        let abandoned = load.waiters.isEmpty
        if abandoned {
            pending[path] = nil
        }
        lock.unlock()
        if abandoned {
            load.operation.cancel()
        }
    }
    
    private func finish(path: String, load: PendingLoad, image: NSImage?) {
        lock.lock()
        guard pending[path] === load else {
            lock.unlock()
            return
        }
        pending[path] = nil
        let waiters = Array(load.waiters.values)
        lock.unlock()
        DispatchQueue.main.async {
            waiters.forEach { $0(image) }
        }
    }
    
    private func render(path: String, targetPixels: CGFloat) -> Rendered? {
        return autoreleasepool {
            let url = URL(fileURLWithPath: path)
            // Fast-path directories to system folder icon
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                return Rendered(image: icon(for: path, targetPixels: targetPixels), cost: 64 * 1024, cacheable: true)
            }
            
            let ext = url.pathExtension.lowercased()
            
            // For standard image formats: use CoreGraphics downsampled decoding (only decodes thumbnail, never full 48MP bitmap!)
            let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"]
            if imageExtensions.contains(ext) {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: Int(targetPixels)
                ]
                
                if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                    let w = CGFloat(cgImage.width)
                    let h = CGFloat(cgImage.height)
                    let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: w / 2.0, height: h / 2.0))
                    return Rendered(image: thumbnail, cost: cgImage.width * cgImage.height * 4, cacheable: true)
                }
            }
            
            // For videos and complex formats: use QuickLookThumbnailGenerator. Wait for it here so the
            // queue's concurrency limit also covers QuickLook work.
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: targetPixels / 2, height: targetPixels / 2),
                scale: 2.0,
                representationTypes: .thumbnail
            )
            let box = RenderBox()
            let semaphore = DispatchSemaphore(value: 0)
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                if let rep = rep {
                    let cgImage = rep.cgImage
                    box.value = Rendered(image: rep.nsImage, cost: cgImage.width * cgImage.height * 4, cacheable: true)
                }
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 15) == .timedOut {
                QLThumbnailGenerator.shared.cancel(request)
            }
            if let rendered = box.value {
                return rendered
            }
            
            // Fallback to system icon
            return Rendered(image: icon(for: path, targetPixels: targetPixels), cost: 64 * 1024, cacheable: false)
        }
    }
    
    private func icon(for path: String, targetPixels: CGFloat) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: path)
        let side = max(targetPixels / 2, 128)
        icon.size = NSSize(width: side, height: side)
        return icon
    }
}
