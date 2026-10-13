import Foundation

public final class SecurityBookmarkManager {
    public static let shared = SecurityBookmarkManager()
    private let userDefaultsKey = "com.synaps.security_bookmarks"
    private var activeAccessURLs: [String: URL] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    public func saveBookmark(for url: URL) {
        let stdURL = url.standardizedFileURL
        do {
            let data = try stdURL.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            var bookmarks = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Data] ?? [:]
            bookmarks[stdURL.path] = data
            UserDefaults.standard.set(bookmarks, forKey: userDefaultsKey)
        } catch {
            // Non-sandboxed development builds may throw when requesting security scope
            do {
                let data = try stdURL.bookmarkData(
                    options: .suitableForBookmarkFile,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                var bookmarks = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Data] ?? [:]
                bookmarks[stdURL.path] = data
                UserDefaults.standard.set(bookmarks, forKey: userDefaultsKey)
            } catch {
                // Silently fallback if bookmarks not required for path
            }
        }
    }
    
    @discardableResult
    public func startAccessing(path: String) -> URL {
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        let pathKey = originalURL.path
        
        lock.lock()
        defer { lock.unlock() }
        
        if let active = activeAccessURLs[pathKey] {
            return active
        }
        
        let bookmarks = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Data] ?? [:]
        if let data = bookmarks[pathKey] {
            var isStale = false
            if let resolvedURL = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                if resolvedURL.startAccessingSecurityScopedResource() {
                    activeAccessURLs[pathKey] = resolvedURL
                    if isStale {
                        saveBookmark(for: resolvedURL)
                    }
                    return resolvedURL
                }
            }
        }
        
        // Attempt starting access directly
        if originalURL.startAccessingSecurityScopedResource() {
            activeAccessURLs[pathKey] = originalURL
        }
        saveBookmark(for: originalURL)
        return originalURL
    }
    
    public func stopAccessing(path: String) {
        let pathKey = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        
        if let active = activeAccessURLs.removeValue(forKey: pathKey) {
            active.stopAccessingSecurityScopedResource()
        }
    }
}
