import Foundation
import AppKit
import ImageIO
import QuickLookThumbnailing

public final class ThumbnailLoader {
    public static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()
    private let queue = DispatchQueue(label: "com.synaps.thumbnailqueue", qos: .utility, attributes: .concurrent)
    
    private init() {
        cache.countLimit = 150
        cache.totalCostLimit = 60 * 1024 * 1024 // Strict 60 MB maximum RAM limit!
    }
    
    public func loadThumbnail(for path: String, targetSize: CGFloat = 200, completion: @escaping (NSImage?) -> Void) {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached)
            return
        }
        
        queue.async {
            autoreleasepool {
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                
                // For standard image formats: use CoreGraphics downsampled decoding (only decodes thumbnail, never full 48MP bitmap!)
                let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"]
                if imageExtensions.contains(ext) {
                    let options: [CFString: Any] = [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: Int(targetSize * 2) // 2x for Retina displays
                    ]
                    
                    if let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                        let thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: targetSize, height: targetSize))
                        self.cache.setObject(thumbnail, forKey: key, cost: Int(targetSize * targetSize * 4))
                        DispatchQueue.main.async {
                            completion(thumbnail)
                        }
                        return
                    }
                }
                
                // For videos and complex formats: use QuickLookThumbnailGenerator
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: targetSize, height: targetSize),
                    scale: 2.0,
                    representationTypes: .thumbnail
                )
                
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    if let rep = rep {
                        let img = rep.nsImage
                        self.cache.setObject(img, forKey: key, cost: Int(targetSize * targetSize * 4))
                        DispatchQueue.main.async {
                            completion(img)
                        }
                    } else {
                        // Fallback to system icon
                        let icon = NSWorkspace.shared.icon(forFile: path)
                        DispatchQueue.main.async {
                            completion(icon)
                        }
                    }
                }
            }
        }
    }
}
