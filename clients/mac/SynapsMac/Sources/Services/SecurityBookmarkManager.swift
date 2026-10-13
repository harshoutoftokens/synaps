import Foundation

public final class SecurityBookmarkManager: @unchecked Sendable {
    public static let shared = SecurityBookmarkManager()
    private let userDefaultsKey = "com.synaps.security_bookmarks"
    private var activeAccessURLs: [String: URL] = [:]
    /// Nested/concurrent scans of the same folder each start and stop access; only the last stop ends it.
    private var activeAccessCounts: [String: Int] = [:]
    private let lock = NSLock()
    
    /// Security scope only exists inside the App Sandbox. The current build isn't sandboxed (no
    /// com.apple.security.app-sandbox entitlement), where every call used to fail to start access and
    /// then re-create a bookmark and rewrite a UserDefaults dictionary that grew with every folder seen.
    private static let isSandboxed: Bool = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    
    private init() {}
    
    public func saveBookmark(for url: URL) {
        guard Self.isSandboxed else { return }
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
            // Without user-granted access there is nothing to bookmark yet
        }
    }
    
    @discardableResult
    public func startAccessing(path: String) -> URL {
        let originalURL = URL(fileURLWithPath: path).standardizedFileURL
        guard Self.isSandboxed else { return originalURL }
        let pathKey = originalURL.path
        
        lock.lock()
        defer { lock.unlock() }
        
        if let active = activeAccessURLs[pathKey] {
            activeAccessCounts[pathKey, default: 1] += 1
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
                    activeAccessCounts[pathKey] = 1
                    if isStale {
                        saveBookmark(for: resolvedURL)
                    }
                    return resolvedURL
                }
            }
        }
        
        // Attempt starting access directly (e.g. a folder the user just picked)
        if originalURL.startAccessingSecurityScopedResource() {
            activeAccessURLs[pathKey] = originalURL
            activeAccessCounts[pathKey] = 1
            if bookmarks[pathKey] == nil {
                saveBookmark(for: originalURL)
            }
        }
        return originalURL
    }
    
    public func stopAccessing(path: String) {
        guard Self.isSandboxed else { return }
        let pathKey = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        defer { lock.unlock() }
        
        guard let count = activeAccessCounts[pathKey] else { return }
        if count > 1 {
            activeAccessCounts[pathKey] = count - 1
            return
        }
        activeAccessCounts[pathKey] = nil
        if let active = activeAccessURLs.removeValue(forKey: pathKey) {
            active.stopAccessingSecurityScopedResource()
        }
    }
}
