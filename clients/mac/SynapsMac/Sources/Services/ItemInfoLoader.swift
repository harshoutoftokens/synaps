import Foundation
import ImageIO
import AVFoundation

public final class ItemInfoLoader {
    public static let shared = ItemInfoLoader()
    private let cache = NSCache<NSString, NSString>()
    private let queue = DispatchQueue(label: "com.synaps.iteminfoqueue", qos: .utility, attributes: .concurrent)
    
    private init() {
        cache.countLimit = 600
    }
    
    public func getCachedInfo(for path: String) -> String? {
        return cache.object(forKey: path as NSString) as String?
    }
    
    public func loadInfo(for item: SynapsFileItem, completion: @escaping (String) -> Void) {
        let key = item.originalPath as NSString
        if let cached = cache.object(forKey: key) {
            completion(cached as String)
            return
        }
        
        queue.async {
            var info: String = ""
            
            if item.isDirectory {
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: item.originalPath) {
                    let nonHidden = contents.filter { !$0.hasPrefix(".") }
                    info = nonHidden.count == 1 ? "1 item" : "\(nonHidden.count) items"
                } else {
                    info = "--"
                }
            } else if item.originalPath.hasPrefix("iPhone://") || item.originalPath.hasPrefix("nas://") {
                info = item.formattedSize
            } else {
                let ext = (item.filename as NSString).pathExtension.lowercased()
                let imageExts = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff"]
                let videoExts = ["mov", "mp4", "m4v", "avi", "mkv"]
                
                if imageExts.contains(ext) {
                    let url = URL(fileURLWithPath: item.originalPath)
                    if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                       let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                       let w = props[kCGImagePropertyPixelWidth] as? Int,
                       let h = props[kCGImagePropertyPixelHeight] as? Int {
                        let nf = NumberFormatter()
                        nf.numberStyle = .decimal
                        let wStr = nf.string(from: NSNumber(value: w)) ?? "\(w)"
                        let hStr = nf.string(from: NSNumber(value: h)) ?? "\(h)"
                        info = "\(wStr) × \(hStr)"
                    } else {
                        info = item.formattedSize
                    }
                } else if videoExts.contains(ext) {
                    let url = URL(fileURLWithPath: item.originalPath)
                    let asset = AVURLAsset(url: url)
                    Task {
                        var videoInfo = item.formattedSize
                        if let duration = try? await asset.load(.duration) {
                            let seconds = CMTimeGetSeconds(duration)
                            if !seconds.isNaN && seconds > 0 {
                                let totalSec = Int(seconds.rounded())
                                let mins = totalSec / 60
                                let secs = totalSec % 60
                                let hours = mins / 60
                                if hours > 0 {
                                    videoInfo = String(format: "%d:%02d:%02d", hours, mins % 60, secs)
                                } else {
                                    videoInfo = String(format: "%02d:%02d", mins, secs)
                                }
                            }
                        }
                        self.cache.setObject(videoInfo as NSString, forKey: key)
                        DispatchQueue.main.async {
                            completion(videoInfo)
                        }
                    }
                    return
                } else {
                    info = item.formattedSize
                }
            }
            
            self.cache.setObject(info as NSString, forKey: key)
            DispatchQueue.main.async {
                completion(info)
            }
        }
    }
}
