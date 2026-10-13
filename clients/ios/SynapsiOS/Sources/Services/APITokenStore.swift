import Foundation
import Security

/// Stores the optional NAS API token (SYNAPS_API_TOKEN on the server) in the Keychain as a
/// generic password. It is readable after the first unlock so BGTasks and background-URLSession
/// relaunches can authenticate while the phone is locked. The value is cached in memory so
/// building a request never hits the Keychain.
public enum APITokenStore {
    private static let service = "com.synaps.ios.api-token"
    private static let account = "nas"
    private static let lock = NSLock()
    /// nil = not loaded yet; .some(nil) = loaded, no token stored.
    nonisolated(unsafe) private static var cached: String??
    
    /// The current token, or nil when none is configured (requests are then sent without auth).
    public static func token() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached {
            return cached
        }
        let value = readFromKeychain()
        cached = .some(value)
        return value
    }
    
    /// Saves (or, for nil/blank input, deletes) the token. Returns false if the Keychain refused.
    @discardableResult
    public static func setToken(_ newValue: String?) -> Bool {
        let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lock.lock()
        defer { lock.unlock() }
        let ok = trimmed.isEmpty ? deleteFromKeychain() : writeToKeychain(trimmed)
        cached = ok ? .some(trimmed.isEmpty ? nil : trimmed) : nil
        return ok
    }
    
    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
    
    private static func readFromKeychain() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            if status != errSecSuccess && status != errSecItemNotFound {
                print("Keychain read failed: \(status)")
            }
            return nil
        }
        return token
    }
    
    private static func writeToKeychain(_ token: String) -> Bool {
        let data = Data(token.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess {
            return true
        }
        guard status == errSecItemNotFound else {
            print("Keychain update failed: \(status)")
            return false
        }
        var addQuery = baseQuery
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("Keychain add failed: \(addStatus)")
        }
        return addStatus == errSecSuccess
    }
    
    private static func deleteFromKeychain() -> Bool {
        let status = SecItemDelete(baseQuery as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
