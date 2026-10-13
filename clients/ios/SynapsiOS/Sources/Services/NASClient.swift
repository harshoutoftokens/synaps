import Foundation

// MARK: - Wire models (field names match backend/routers/ingest_v2.py)

public struct IngestCheckFilePayload: Codable, Sendable {
    public let original_path: String
    public let original_filename: String
    public let file_size: Int64
    public let source_location: String
    public let source_modified_at: String?
    public let client_sha256: String
    public let is_favorite: Bool?
}

public struct IngestSourcePayload: Codable, Sendable {
    public let id: String
    public let friendly_name: String
    public let platform: String
    public let volume_identifier: String?
}

public struct IngestCheckBatchRequest: Codable, Sendable {
    public let source: IngestSourcePayload
    public let files: [IngestCheckFilePayload]
}

public struct IngestCheckItemResult: Codable, Sendable {
    public let original_path: String
    public let status: String // "dedup_linked" or "need_upload"
    public let sha256: String?
    public let error: String?
    // physical_object_id is intentionally not decoded: its JSON type (int vs UUID string) is a
    // server implementation detail and a mismatch would fail the whole batch.
}

public struct IngestCheckBatchResponse: Codable, Sendable {
    public let source_id: String?
    public let status: String?
    public let total_checked: Int?
    public let dedup_linked: Int?
    public let need_upload: Int?
    public let results: [IngestCheckItemResult]
}

/// One file to look up with POST /api/v2/ingest/match.
public struct IngestMatchFile: Codable, Sendable, Hashable {
    public let filename: String
    public let size: Int64
    
    public init(filename: String, size: Int64) {
        self.filename = filename
        self.size = size
    }
}

/// A file the NAS already holds (uploaded from any device), with its content hash.
public struct IngestMatch: Codable, Sendable {
    public let filename: String
    public let size: Int64
    public let sha256: String
}

private struct IngestMatchRequest: Codable {
    let files: [IngestMatchFile]
}

private struct IngestMatchResponse: Codable {
    let matches: [IngestMatch]
}

/// Response of POST /api/v2/ingest/upload and PUT /api/v2/ingest/stream (only the fields we use).
public struct IngestUploadResponse: Decodable, Sendable {
    public let status: String?
    public let sha256: String?
    public let canonical_path: String?
    public let mirror_path: String?
}

/// Upload metadata shared by the stream (query string) and multipart (form fields) endpoints.
public struct IngestUploadFields: Codable, Sendable {
    public var sourceId: String
    public var originalPath: String
    public var originalFilename: String
    public var sourceLocation: String
    public var clientSHA256: String
    public var sourceCreatedAt: String?
    public var sourceModifiedAt: String?
    public var isFavorite: Bool
    
    public var formFields: [(String, String)] {
        var fields: [(String, String)] = [
            ("source_id", sourceId),
            ("original_path", originalPath),
            ("original_filename", originalFilename),
            ("source_location", sourceLocation),
            ("client_sha256", clientSHA256)
        ]
        if let sourceCreatedAt { fields.append(("source_created_at", sourceCreatedAt)) }
        if let sourceModifiedAt { fields.append(("source_modified_at", sourceModifiedAt)) }
        fields.append(("is_favorite", isFavorite ? "true" : "false"))
        return fields
    }
}

public enum NASError: LocalizedError, Sendable, Equatable {
    case invalidURL(String)
    case unauthorized
    case http(status: Int, detail: String?)
    case invalidResponse
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid NAS URL: \(url)"
        case .unauthorized:
            return "API token missing or wrong (the NAS answered 401). Check Settings → API Token."
        case .http(let status, let detail):
            if let detail, !detail.isEmpty {
                return "NAS error \(status): \(detail)"
            }
            return "NAS error \(status)"
        case .invalidResponse:
            return "Unexpected response from the NAS"
        }
    }
    
    /// Worth retrying with backoff (server overloaded / temporarily failing).
    public var isTransient: Bool {
        if case .http(let status, _) = self {
            return status == 408 || status == 429 || status == 500 || status == 502 || status == 503 || status == 504
        }
        return false
    }
}

public final class NASClient: @unchecked Sendable {
    public static let shared = NASClient()
    
    private let session: URLSession
    private let probeSession: URLSession
    private let lock = NSLock()
    private var _streamEndpointUnsupported = false // guarded by lock
    private var healthProbe: (base: String, task: Task<Bool, Never>)? // guarded by lock
    private var lastHealth: (base: String, date: Date, ok: Bool)?    // guarded by lock
    
    #if DEBUG
    /// Launch argument for simulator testing against a local mock server, e.g.
    /// `-SynapsNASURLOverride http://127.0.0.1:8765`. Compiled out of release builds.
    static let debugURLOverrideKey = "SynapsNASURLOverride"
    #endif
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.httpMaximumConnectionsPerHost = 2
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
        
        let probe = URLSessionConfiguration.ephemeral
        probe.timeoutIntervalForRequest = 4
        probe.timeoutIntervalForResource = 6
        probe.waitsForConnectivity = false
        probeSession = URLSession(configuration: probe)
    }
    
    // MARK: - Base URL & request building
    
    /// "192.168.0.105:8000/" -> "http://192.168.0.105:8000"
    public static func normalizeBaseURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") {
            url.removeLast()
        }
        if !url.isEmpty && !url.contains("://") {
            url = "http://" + url
        }
        return url
    }
    
    public func getBaseUrl() -> String {
        #if DEBUG
        if let override = UserDefaults.standard.string(forKey: Self.debugURLOverrideKey), !override.isEmpty {
            return Self.normalizeBaseURL(override)
        }
        #endif
        return Self.normalizeBaseURL(SynapsConfig.load().nasUrl)
    }
    
    /// Builds a request against the configured NAS. Every request goes through here so the
    /// optional API token (Authorization: Bearer) is attached uniformly.
    public func makeRequest(
        path: String,
        query: [(String, String)] = [],
        method: String = "GET",
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        let base = getBaseUrl()
        var urlString = base + path
        if !query.isEmpty {
            let encoded = Self.encodeQuery(query)
            assert(!encoded.contains("+"), "a raw '+' in the query would reach the server as a space")
            urlString += "?" + encoded
        }
        guard let url = URL(string: urlString), url.scheme != nil, url.host != nil else {
            throw NASError.invalidURL(base)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = APITokenStore.token(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }
    
    private static let queryValueAllowed: CharacterSet = {
        // RFC 3986 unreserved characters only (ASCII). Notably '+' is escaped: the server decodes
        // query strings form-style, so a raw '+' would arrive as a space ("+00:00", "IMG+1.JPG").
        var set = CharacterSet()
        set.insert(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return set
    }()
    
    public static func encodeQuery(_ items: [(String, String)]) -> String {
        items.map { key, value in
            let k = key.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? key
            let v = value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? value
            return "\(k)=\(v)"
        }.joined(separator: "&")
    }
    
    private static let isoFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .autoupdatingCurrent
        // Local wall-clock time with an explicit numeric offset ("+05:30", never "Z"):
        // unambiguous, parsed by datetime.fromisoformat() on every Python version ("Z" needs 3.11+),
        // and if the server drops tzinfo it keeps the local time like its EXIF-derived dates.
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return f
    }()
    
    /// ISO-8601 timestamp accepted by Python's datetime.fromisoformat() on every version.
    public static func isoTimestamp(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }
    
    /// Maps non-2xx responses to NASError (401 -> .unauthorized, FastAPI "detail" surfaced).
    @discardableResult
    static func validate(_ response: URLResponse, data: Data) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw NASError.invalidResponse
        }
        if http.statusCode == 401 {
            throw NASError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw NASError.http(status: http.statusCode, detail: errorDetail(from: data))
        }
        return http
    }
    
    static func errorDetail(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = json["detail"] {
            if let text = detail as? String {
                return text
            }
            return String(describing: detail).prefix(300).description
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    
    /// URLError codes that indicate a temporary condition worth retrying.
    public static func isTransient(_ error: Error) -> Bool {
        if let nasError = error as? NASError {
            return nasError.isTransient
        }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .dataNotAllowed,
             .internationalRoamingOff, .callIsActive, .backgroundSessionWasDisconnected:
            return true
        default:
            return false
        }
    }
    
    // MARK: - Health
    
    /// Probes only the configured NAS URL. (Earlier builds also probed hard-coded LAN IPs /
    /// localhost and silently persisted whichever answered first, which could redirect uploads —
    /// and, with token auth, the API token — to an unrelated host.)
    /// Concurrent callers share one probe and results are reused for 3 s (launch, foreground,
    /// Wi-Fi join and the sync run all ask at about the same time).
    public func checkHealth() async -> Bool {
        let base = getBaseUrl()
        let probe: Task<Bool, Never> = lock.withLock {
            if let probe = healthProbe, probe.base == base {
                return probe.task
            }
            if let last = lastHealth, last.base == base, Date().timeIntervalSince(last.date) < 3 {
                let ok = last.ok
                return Task { ok }
            }
            let task = Task { await self.probeHealth() }
            healthProbe = (base, task)
            return task
        }
        let ok = await probe.value
        lock.withLock {
            if healthProbe?.task == probe {
                healthProbe = nil
                lastHealth = (base, Date(), ok)
            }
        }
        return ok
    }
    
    /// UserDefaults key of the host name the NAS reported in its last health check.
    public static let serverNameKey = "nasServerName"
    
    private func probeHealth() async -> Bool {
        for path in ["/api/health", "/health"] {
            guard let request = try? makeRequest(path: path, timeout: 4) else { return false }
            do {
                let (data, response) = try await probeSession.data(for: request)
                guard let http = response as? HTTPURLResponse else { return false }
                if http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    if let name = json["name"] as? String, !name.isEmpty {
                        // The NAS's host name ("homecloud1"), shown instead of its IP (Lock Screen banner)
                        UserDefaults.standard.set(name, forKey: Self.serverNameKey)
                    }
                    return true
                }
                // Reachable but this path isn't the health endpoint (very old server): try the next one.
            } catch {
                return false // host unreachable; the second path won't fare better
            }
        }
        return false
    }
    
    public enum AccessCheck: Sendable, Equatable {
        case ok
        case unreachable
        case unauthorized
        case failed(String)
    }
    
    /// Health check plus one authenticated call, so "Test Connection" can tell a wrong/missing
    /// API token apart from an unreachable NAS (/api/health itself is exempt from auth).
    public func verifyAccess() async -> AccessCheck {
        guard await checkHealth() else { return .unreachable }
        do {
            let request = try makeRequest(path: "/api/finder/browse", query: [("page", "1"), ("per_page", "1")], timeout: 10)
            let (data, response) = try await probeSession.data(for: request)
            try Self.validate(response, data: data)
            return .ok
        } catch NASError.unauthorized {
            return .unauthorized
        } catch NASError.http(let status, _) where status == 404 {
            return .ok // storage root missing on the server; auth itself passed
        } catch {
            return .failed(error.localizedDescription)
        }
    }
    
    // MARK: - Ingest
    
    public func batchPreCheck(
        sourceId: String,
        friendlyName: String,
        files: [IngestCheckFilePayload],
        allowsExpensiveNetwork: Bool = true
    ) async throws -> IngestCheckBatchResponse {
        var request = try makeRequest(path: "/api/v2/ingest/check", method: "POST", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        request.httpBody = try JSONEncoder().encode(IngestCheckBatchRequest(
            source: IngestSourcePayload(id: sourceId, friendly_name: friendlyName, platform: "ios", volume_identifier: nil),
            files: files
        ))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(IngestCheckBatchResponse.self, from: data)
    }
    
    /// Largest batch the server accepts for `matchExisting`.
    public static let maxMatchBatchSize = 2000
    
    /// POST /api/v2/ingest/match — which of these (file name, size) pairs the NAS already has,
    /// from any device. Read-only on the server. Older servers answer 404.
    public func matchExisting(_ files: [IngestMatchFile]) async throws -> [IngestMatch] {
        var request = try makeRequest(path: "/api/v2/ingest/match", method: "POST", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(IngestMatchRequest(files: files))
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(IngestMatchResponse.self, from: data).matches
    }
    
    /// Set once the server answered 404/405 to PUT /api/v2/ingest/stream; remembered for the
    /// rest of the session so later uploads go straight to the multipart endpoint.
    public var streamEndpointUnsupported: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _streamEndpointUnsupported
        }
        set {
            lock.lock()
            _streamEndpointUnsupported = newValue
            lock.unlock()
        }
    }
    
    /// PUT /api/v2/ingest/stream — raw file body, metadata in the query string.
    public func streamUploadRequest(fields: IngestUploadFields, allowsExpensiveNetwork: Bool) throws -> URLRequest {
        var request = try makeRequest(path: "/api/v2/ingest/stream", query: fields.formFields, method: "PUT", timeout: 300)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        return request
    }
    
    /// POST /api/v2/ingest/upload — legacy multipart endpoint (fallback for older servers).
    public func multipartUploadRequest(boundary: String, allowsExpensiveNetwork: Bool) throws -> URLRequest {
        var request = try makeRequest(path: "/api/v2/ingest/upload", method: "POST", timeout: 300)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.allowsExpensiveNetworkAccess = allowsExpensiveNetwork
        request.allowsConstrainedNetworkAccess = allowsExpensiveNetwork
        return request
    }
    
    /// Streams a multipart/form-data body (form fields + file) into `bodyURL` in 4 MB chunks.
    public static func writeMultipartBody(fields: IngestUploadFields, fileURL: URL, to bodyURL: URL, boundary: String) throws {
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: bodyURL)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        
        var header = ""
        for (name, value) in fields.formFields {
            header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        }
        let safeName = fields.originalFilename
            .replacingOccurrences(of: "\"", with: "%22")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(header.utf8))
        
        while true {
            if Task.isCancelled {
                throw CancellationError()
            }
            let done: Bool = try autoreleasepool {
                guard let chunk = try input.read(upToCount: HashEngine.chunkSize), !chunk.isEmpty else {
                    return true
                }
                try output.write(contentsOf: chunk)
                return false
            }
            if done { break }
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
    }
    
    // MARK: - Vault browsing
    
    public func browseDirectory(path: String = "", page: Int = 1, perPage: Int = 200) async throws -> NASBrowseResponse {
        var query = [
            ("page", "\(max(1, page))"),
            ("per_page", "\(min(max(1, perPage), 1000))")
        ]
        if !path.isEmpty && path != "/" {
            query.append(("path", path))
        }
        let request = try makeRequest(path: "/api/finder/browse", query: query, timeout: 20)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            return NASBrowseResponse(current_path: path, folders: [], files: [], total_folders: 0, total_files: 0, page: page, per_page: perPage)
        }
        try Self.validate(response, data: data)
        return try JSONDecoder().decode(NASBrowseResponse.self, from: data)
    }
    
    /// GET /api/finder/thumbnail (200 = WebP, 202 = generation queued; poll again).
    public func thumbnailRequest(for relativePath: String) throws -> URLRequest {
        try makeRequest(path: "/api/finder/thumbnail", query: [("path", relativePath)], timeout: 15)
    }
}
