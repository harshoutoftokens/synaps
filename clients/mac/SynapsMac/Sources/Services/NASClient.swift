import Foundation

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
    public let physical_object_id: String?
    
    public init(
        original_path: String,
        status: String,
        sha256: String? = nil,
        error: String? = nil,
        physical_object_id: String? = nil
    ) {
        self.original_path = original_path
        self.status = status
        self.sha256 = sha256
        self.error = error
        self.physical_object_id = physical_object_id
    }
    
    private enum CodingKeys: String, CodingKey {
        case original_path, status, sha256, error, physical_object_id
    }
    
    /// Optional fields never fail the whole batch: e.g. an integer id is accepted as a string.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        original_path = try c.decode(String.self, forKey: .original_path)
        status = try c.decode(String.self, forKey: .status)
        sha256 = try? c.decodeIfPresent(String.self, forKey: .sha256)
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        if let id = try? c.decodeIfPresent(String.self, forKey: .physical_object_id) {
            physical_object_id = id
        } else if let id = try? c.decodeIfPresent(Int.self, forKey: .physical_object_id) {
            physical_object_id = String(id)
        } else {
            physical_object_id = nil
        }
    }
}

public struct IngestCheckBatchResponse: Codable, Sendable {
    public let source_id: String?
    public let status: String?
    public let total_checked: Int?
    public let dedup_linked: Int?
    public let dedup_count: Int?
    public let need_upload: Int?
    public let need_upload_count: Int?
    public let results: [IngestCheckItemResult]
    
    public init(
        source_id: String? = nil,
        status: String? = nil,
        total_checked: Int? = nil,
        dedup_linked: Int? = nil,
        dedup_count: Int? = nil,
        need_upload: Int? = nil,
        need_upload_count: Int? = nil,
        results: [IngestCheckItemResult] = []
    ) {
        self.source_id = source_id
        self.status = status
        self.total_checked = total_checked
        self.dedup_linked = dedup_linked
        self.dedup_count = dedup_count
        self.need_upload = need_upload
        self.need_upload_count = need_upload_count
        self.results = results
    }
    
    public var dedupCount: Int {
        return dedup_linked ?? dedup_count ?? results.filter { $0.status == "dedup_linked" }.count
    }
    
    public var needUploadCount: Int {
        return need_upload ?? need_upload_count ?? results.filter { $0.status == "need_upload" }.count
    }
}

public struct AlbumSyncPayload: Codable, Sendable {
    public let source_id: String
    public let album_name: String
    public let original_paths: [String]
}

public struct NASFolderItem: Codable, Sendable {
    public let name: String
    public let path: String
    public let type: String
    public let children_count: Int?
    public let modified: String?
    
    public init(name: String, path: String, type: String = "folder", children_count: Int? = nil, modified: String? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.children_count = children_count
        self.modified = modified
    }
}

public struct NASFileItem: Codable, Sendable {
    public let name: String
    public let path: String
    public let type: String
    public let file_type: String?
    public let `extension`: String?
    public let mime_type: String?
    public let size: Int64
    public let size_human: String?
    public let modified: String?
    
    public init(
        name: String,
        path: String,
        type: String = "file",
        file_type: String? = nil,
        extension: String? = nil,
        mime_type: String? = nil,
        size: Int64 = 0,
        size_human: String? = nil,
        modified: String? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.file_type = file_type
        self.extension = `extension`
        self.mime_type = mime_type
        self.size = size
        self.size_human = size_human
        self.modified = modified
    }
}

public struct NASBrowseResponse: Codable, Sendable {
    public let current_path: String
    public let folders: [NASFolderItem]
    public let files: [NASFileItem]
    public let total_folders: Int
    public let total_files: Int
    public let page: Int
    public let per_page: Int
    
    public init(
        current_path: String = "",
        folders: [NASFolderItem] = [],
        files: [NASFileItem] = [],
        total_folders: Int = 0,
        total_files: Int = 0,
        page: Int = 1,
        per_page: Int = 0
    ) {
        self.current_path = current_path
        self.folders = folders
        self.files = files
        self.total_folders = total_folders
        self.total_files = total_files
        self.page = page
        self.per_page = per_page
    }
}

/// Parsed `200 {"status":"success", ...}` body of /api/v2/ingest/stream and /api/v2/ingest/upload.
public struct IngestUploadResult: Sendable {
    public let status: String
    public let sha256: String?
    public let canonicalPath: String?
    public let mirrorPath: String?
    /// False when the server lacked PUT /api/v2/ingest/stream and the multipart endpoint was used.
    public let usedStreamEndpoint: Bool
}

public enum NASClientError: LocalizedError, Equatable {
    /// 401 — SYNAPS_API_TOKEN is set on the NAS and our token is missing or wrong.
    case unauthorized
    case httpStatus(Int, String?)
    case invalidResponse
    case missingChecksum
    case fileUnreadable(String)
    
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "API token missing or wrong (HTTP 401). Check it in Settings."
        case .httpStatus(507, _):
            return "Home Cloud's disk is full (HTTP 507)"
        case .httpStatus(let code, let detail):
            if let detail = detail, !detail.isEmpty {
                return "HTTP \(code): \(detail)"
            }
            return "HTTP \(code)"
        case .invalidResponse:
            return "Unexpected response from Home Cloud"
        case .missingChecksum:
            return "File could not be hashed"
        case .fileUnreadable(let path):
            return "Cannot read \((path as NSString).lastPathComponent)"
        }
    }
    
    /// 507 from the upload endpoints: no point sending more files.
    public var isDiskFull: Bool {
        if case .httpStatus(507, _) = self {
            return true
        }
        return false
    }
    
    /// 400 from the upload endpoints when the received bytes don't hash to client_sha256
    /// (usually the file changed after it was hashed).
    public var isChecksumMismatch: Bool {
        if case .httpStatus(400, let detail) = self {
            return detail?.contains("SHA-256 mismatch") ?? false
        }
        return false
    }
}

public final class NASClient: @unchecked Sendable {
    public static let shared = NASClient()
    
    /// Posted (from any thread) whenever the NAS answers 401.
    public static let unauthorizedNotification = Notification.Name("SynapsNASUnauthorized")
    
    /// /api/v2/ingest/check requests carry at most this many files.
    public static let maxCheckBatchSize = 200
    
    /// Addresses `discoverNAS()` suggests when the configured NAS stops answering (e.g. after a DHCP
    /// change). Localhost is deliberately not a candidate: a dev backend on this Mac must never be
    /// mistaken for the real NAS. Enter it in Settings to use it.
    private static let discoveryCandidates = [
        "http://192.168.0.105:8000",
        "http://192.168.0.101:8000",
        "http://homecloud1.local:8000"
    ]
    
    private let lock = NSLock()
    private var activeBaseUrl: String
    private var apiToken: String
    /// nil = not yet known for the current server; false = no PUT /api/v2/ingest/stream (use multipart).
    private var streamUploadSupported: Bool?
    
    /// Small JSON calls (browse, check, albums).
    private let apiSession: URLSession
    /// Uploads: long resource timeout for multi-GB files; 2 connections match the upload concurrency.
    private let uploadSession: URLSession
    private let downloadSession: URLSession
    /// Health probes: short timeouts, never carries the API token (health is exempt from auth and
    /// discovery probes other LAN hosts).
    private let healthSession: URLSession
    private let uploadTempDir: URL
    /// Throwaway clients (Settings' "Test Connection") must not flag the app-wide auth state.
    private let reportsAuthFailures: Bool
    
    private convenience init() {
        let cfg = SynapsConfig.load()
        self.init(baseUrl: cfg.nasUrl, apiToken: cfg.apiToken)
        // Multipart bodies left behind by a previous run that crashed mid-upload
        try? FileManager.default.removeItem(at: uploadTempDir)
    }
    
    /// Standalone client for another address/token (Settings' connection test). Tests inject
    /// URLProtocol stubs through `protocolClasses`. Call `invalidate()` when done.
    init(baseUrl: String, apiToken: String = "", reportsAuthFailures: Bool = true, protocolClasses: [AnyClass]? = nil) {
        self.activeBaseUrl = SynapsConfig.normalizedURLString(baseUrl)
        self.apiToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.reportsAuthFailures = reportsAuthFailures
        
        func makeConfiguration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval, maxConnections: Int) -> URLSessionConfiguration {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = requestTimeout
            config.timeoutIntervalForResource = resourceTimeout
            config.httpMaximumConnectionsPerHost = maxConnections
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            if let protocolClasses = protocolClasses {
                config.protocolClasses = protocolClasses + (config.protocolClasses ?? [])
            }
            return config
        }
        
        apiSession = URLSession(configuration: makeConfiguration(requestTimeout: 30, resourceTimeout: 300, maxConnections: 4))
        uploadSession = URLSession(configuration: makeConfiguration(requestTimeout: 300, resourceTimeout: 24 * 60 * 60, maxConnections: 2))
        downloadSession = URLSession(configuration: makeConfiguration(requestTimeout: 120, resourceTimeout: 24 * 60 * 60, maxConnections: 4))
        healthSession = URLSession(configuration: makeConfiguration(requestTimeout: 3, resourceTimeout: 5, maxConnections: 2))
        uploadTempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SynapsUploads", isDirectory: true)
    }
    
    // MARK: - Configuration
    
    public func setBaseUrl(_ url: String) {
        let normalized = SynapsConfig.normalizedURLString(url)
        lock.lock()
        if normalized != activeBaseUrl {
            streamUploadSupported = nil
        }
        activeBaseUrl = normalized
        lock.unlock()
    }
    
    public func getBaseUrl() -> String {
        lock.lock()
        defer { lock.unlock() }
        return activeBaseUrl
    }
    
    public func setApiToken(_ token: String) {
        lock.lock()
        apiToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.unlock()
    }
    
    public var hasApiToken: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !apiToken.isEmpty
    }
    
    /// Applies a saved Settings change (NAS address and API token).
    public func apply(config: SynapsConfig) {
        setBaseUrl(config.nasUrl)
        setApiToken(config.apiToken)
    }
    
    // MARK: - Request building
    
    /// Builds a request against the active NAS with the bearer token attached when configured.
    /// Every NAS call (thumbnails and downloads included) goes through here.
    public func makeRequest(
        path: String,
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        baseUrl: String? = nil,
        timeout: TimeInterval = 30
    ) throws -> URLRequest {
        guard var components = URLComponents(string: (baseUrl ?? getBaseUrl()) + path) else {
            throw URLError(.badURL)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
            // URLComponents leaves "+" as-is, but the backend decodes "+" in a query as a space,
            // which broke paths like "C++ notes.pdf". Encode it explicitly.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        applyAuth(to: &request)
        return request
    }
    
    public func applyAuth(to request: inout URLRequest) {
        lock.lock()
        let token = apiToken
        lock.unlock()
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
    
    /// Lets other loaders (thumbnails) report a 401 the same way NASClient does.
    public func reportUnauthorized() {
        guard reportsAuthFailures else { return }
        NotificationCenter.default.post(name: Self.unauthorizedNotification, object: self)
    }
    
    /// Releases the sessions of a standalone client.
    func invalidate() {
        for session in [apiSession, uploadSession, downloadSession, healthSession] {
            session.finishTasksAndInvalidate()
        }
    }
    
    private func checkedHTTP(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw NASClientError.invalidResponse
        }
        if http.statusCode == 401 {
            reportUnauthorized()
            throw NASClientError.unauthorized
        }
        return http
    }
    
    private static func requireSuccess(_ http: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(http.statusCode) else {
            throw NASClientError.httpStatus(http.statusCode, errorDetail(from: data))
        }
    }
    
    /// FastAPI puts the reason in {"detail": ...}.
    static func errorDetail(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let detail = json["detail"] {
            return detail as? String ?? String(describing: detail)
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    
    /// ISO8601DateFormatter is thread-safe once configured.
    nonisolated(unsafe) private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    
    /// UTC with an explicit "+00:00": Python < 3.11 `datetime.fromisoformat` rejects the "Z" suffix
    /// ISO8601DateFormatter emits, which silently dropped the timestamps on older NAS installs.
    static func timestampString(_ date: Date) -> String {
        let s = isoFormatter.string(from: date)
        return s.hasSuffix("Z") ? String(s.dropLast()) + "+00:00" : s
    }
    
    // MARK: - Retries
    
    /// Network hiccups, timeouts and 408/429/502/503/504 are worth retrying; 4xx and 500 are not
    /// (a 500 from the upload endpoint usually repeats, and re-sending a multi-GB body is costly).
    public static func isTransient(_ error: Error) -> Bool {
        if let error = error as? NASClientError {
            if case .httpStatus(let code, _) = error {
                return [408, 429, 502, 503, 504].contains(code)
            }
            return false
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable:
                return true
            default:
                return false
            }
        }
        return false
    }
    
    public static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let error = error as? URLError, error.code == .cancelled {
            return true
        }
        return false
    }
    
    /// Exponential backoff with ±20% jitter: ~1s, 2s, 4s, ... capped at `cap`.
    static func backoffNanoseconds(attempt: Int, base: Double = 1.0, cap: Double = 30) -> UInt64 {
        let delay = min(cap, base * pow(2, Double(max(0, attempt - 1)))) * Double.random(in: 0.8...1.2)
        return UInt64(delay * 1_000_000_000)
    }
    
    func withRetries<T>(maxAttempts: Int, _ operation: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, Self.isTransient(error), !Task.isCancelled else {
                    throw error
                }
                try await Task.sleep(nanoseconds: Self.backoffNanoseconds(attempt: attempt))
                attempt += 1
            }
        }
    }
    
    // MARK: - Health & auth
    
    /// Health of the configured NAS only. The configured address is authoritative: a health check
    /// never switches hosts, so a rogue LAN machine answering {"status":"ok"} can't start receiving
    /// files. `discoverNAS()` can suggest another address for the user to confirm.
    public func checkHealth() async -> Bool {
        return await probeHealth(getBaseUrl())
    }
    
    /// Probes the usual LAN addresses (health endpoint only; the API token is never sent to a host
    /// the user hasn't confirmed). Returns responding addresses other than the active one.
    public func discoverNAS() async -> [String] {
        let active = getBaseUrl()
        let candidates = Self.discoveryCandidates.filter { $0 != active }
        let responders: Set<String> = await withTaskGroup(of: String?.self) { group in
            for candidate in candidates {
                group.addTask {
                    return await self.probeHealth(candidate) ? candidate : nil
                }
            }
            var found = Set<String>()
            for await result in group {
                if let candidate = result {
                    found.insert(candidate)
                }
            }
            return found
        }
        return candidates.filter { responders.contains($0) }
    }
    
    private func probeHealth(_ base: String) async -> Bool {
        for path in ["/api/health", "/health"] {
            guard let url = URL(string: "\(base)\(path)") else { return false }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3.0
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            do {
                let (data, response) = try await healthSession.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   json["status"] as? String == "ok" {
                    return true
                }
                // Reachable but this path isn't the health endpoint: try the other one.
            } catch {
                // Candidate offline or connection failed; the other path won't fare better.
                return false
            }
        }
        return false
    }
    
    /// true = token accepted (or not required), false = 401, nil = couldn't tell (network error).
    public func verifyAuth() async -> Bool? {
        guard let request = try? makeRequest(
            path: "/api/finder/browse",
            queryItems: [URLQueryItem(name: "per_page", value: "1")],
            timeout: 10
        ) else { return nil }
        do {
            let (_, response) = try await apiSession.data(for: request)
            _ = try checkedHTTP(response)
            return true
        } catch NASClientError.unauthorized {
            return false
        } catch {
            return nil
        }
    }
    
    // MARK: - Ingest pre-check
    
    /// POSTs /api/v2/ingest/check in requests of at most `maxCheckBatchSize` files and merges the
    /// results (one huge request could exceed the NAS timeout and force every file to re-upload).
    /// Each path is sent once.
    public func batchPreCheck(
        sourceId: String,
        friendlyName: String,
        platform: String,
        items: [SynapsFileItem]
    ) async throws -> IngestCheckBatchResponse {
        var seenPaths = Set<String>()
        let filePayloads = items.compactMap { item -> IngestCheckFilePayload? in
            guard let sha = item.sha256, !sha.isEmpty, seenPaths.insert(item.originalPath).inserted else { return nil }
            return IngestCheckFilePayload(
                original_path: item.originalPath,
                original_filename: item.filename,
                file_size: item.fileSize,
                source_location: item.sourceLocation,
                source_modified_at: Self.timestampString(item.modifiedAt),
                client_sha256: sha,
                is_favorite: item.isFavorite
            )
        }
        let source = IngestSourcePayload(
            id: sourceId,
            friendly_name: friendlyName,
            platform: platform,
            volume_identifier: nil
        )
        guard !filePayloads.isEmpty else {
            return IngestCheckBatchResponse(source_id: sourceId, total_checked: 0, dedup_linked: 0, need_upload: 0, results: [])
        }
        
        var results: [IngestCheckItemResult] = []
        var dedupCount = 0
        var needUploadCount = 0
        var responseSourceId: String? = nil
        for start in stride(from: 0, to: filePayloads.count, by: Self.maxCheckBatchSize) {
            try Task.checkCancellation()
            let chunk = Array(filePayloads[start..<min(start + Self.maxCheckBatchSize, filePayloads.count)])
            let response = try await postCheck(IngestCheckBatchRequest(source: source, files: chunk))
            results.append(contentsOf: response.results)
            dedupCount += response.dedupCount
            needUploadCount += response.needUploadCount
            responseSourceId = response.source_id ?? responseSourceId
        }
        
        return IngestCheckBatchResponse(
            source_id: responseSourceId,
            total_checked: filePayloads.count,
            dedup_linked: dedupCount,
            need_upload: needUploadCount,
            results: results
        )
    }
    
    private func postCheck(_ batchReq: IngestCheckBatchRequest) async throws -> IngestCheckBatchResponse {
        var request = try makeRequest(path: "/api/v2/ingest/check", method: "POST", timeout: 120)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(batchReq)
        
        // Re-sending a check is idempotent: already-linked paths are not linked twice.
        return try await withRetries(maxAttempts: 3) {
            let (data, response) = try await self.apiSession.data(for: request)
            let http = try self.checkedHTTP(response)
            try Self.requireSuccess(http, data)
            return try JSONDecoder().decode(IngestCheckBatchResponse.self, from: data)
        }
    }
    
    // MARK: - Upload
    
    /// Uploads one file straight from disk (never loaded into RAM).
    ///
    /// Prefers `PUT /api/v2/ingest/stream` (raw body); if the NAS answers 404/405 it falls back to the
    /// multipart `POST /api/v2/ingest/upload` and remembers that for the rest of the session.
    /// Throws `NASClientError` (or URLError) on failure; retrying is up to the caller.
    public func uploadFile(
        item: SynapsFileItem,
        sourceId: String,
        progressHandler: (@Sendable (_ bytesSent: Int64, _ totalBytes: Int64) -> Void)? = nil
    ) async throws -> IngestUploadResult {
        guard let sha = item.sha256, !sha.isEmpty else {
            throw NASClientError.missingChecksum
        }
        let fileURL = URL(fileURLWithPath: item.originalPath)
        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw NASClientError.fileUnreadable(item.originalPath)
        }
        
        if await resolveStreamUploadSupport() {
            do {
                return try await streamUpload(item: item, sha: sha, sourceId: sourceId, fileURL: fileURL, progressHandler: progressHandler)
            } catch NASClientError.httpStatus(let code, _) where code == 404 || code == 405 {
                setStreamUploadSupported(false, forBase: getBaseUrl())
                print("ℹ️ [NASClient] PUT /api/v2/ingest/stream unavailable (HTTP \(code)); using multipart uploads for this session")
            }
        }
        return try await multipartUpload(item: item, sha: sha, sourceId: sourceId, fileURL: fileURL, progressHandler: progressHandler)
    }
    
    /// Test hook: nil re-probes, false forces the multipart endpoint, true skips the probe.
    func overrideStreamUploadSupport(_ supported: Bool?) {
        lock.lock()
        streamUploadSupported = supported
        lock.unlock()
    }
    
    private func setStreamUploadSupported(_ supported: Bool, forBase base: String) {
        lock.lock()
        if activeBaseUrl == base {
            streamUploadSupported = supported
        }
        lock.unlock()
    }
    
    /// Probes once per server with a GET on the PUT-only route: 405 means it exists, 404 means an
    /// older backend. Probing first avoids starting a multi-GB body the server would reject.
    private func streamUploadState() -> (known: Bool?, base: String) {
        lock.lock()
        defer { lock.unlock() }
        return (streamUploadSupported, activeBaseUrl)
    }
    
    private func resolveStreamUploadSupport() async -> Bool {
        let (known, base) = streamUploadState()
        if let known = known {
            return known
        }
        guard let request = try? makeRequest(path: "/api/v2/ingest/stream", baseUrl: base, timeout: 10) else {
            return true
        }
        do {
            let (_, response) = try await apiSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return true }
            switch http.statusCode {
            case 404:
                setStreamUploadSupported(false, forBase: base)
                return false
            case 401:
                // Can't tell yet; the upload itself will report the auth problem.
                return true
            default:
                setStreamUploadSupported(true, forBase: base)
                return true
            }
        } catch {
            return true
        }
    }
    
    private func uploadFields(item: SynapsFileItem, sha: String, sourceId: String) -> [(String, String)] {
        return [
            ("source_id", sourceId),
            ("original_path", item.originalPath),
            ("original_filename", item.filename),
            ("source_location", item.sourceLocation),
            ("client_sha256", sha),
            ("source_created_at", Self.timestampString(item.createdAt)),
            ("source_modified_at", Self.timestampString(item.modifiedAt)),
            ("is_favorite", item.isFavorite ? "true" : "false")
        ]
    }
    
    private func streamUpload(
        item: SynapsFileItem,
        sha: String,
        sourceId: String,
        fileURL: URL,
        progressHandler: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> IngestUploadResult {
        var request = try makeRequest(
            path: "/api/v2/ingest/stream",
            queryItems: uploadFields(item: item, sha: sha, sourceId: sourceId).map { URLQueryItem(name: $0.0, value: $0.1) },
            method: "PUT",
            timeout: 300
        )
        // URLSession sets Content-Length from the file size.
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let delegate = progressHandler.map { UploadProgressDelegate(onProgress: $0) }
        let (data, response) = try await uploadSession.upload(for: request, fromFile: fileURL, delegate: delegate)
        return try parseUploadResponse(data: data, response: response, usedStreamEndpoint: true)
    }
    
    private func multipartUpload(
        item: SynapsFileItem,
        sha: String,
        sourceId: String,
        fileURL: URL,
        progressHandler: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> IngestUploadResult {
        var request = try makeRequest(path: "/api/v2/ingest/upload", method: "POST", timeout: 300)
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let bodyURL = try writeMultipartBody(
            boundary: boundary,
            fields: uploadFields(item: item, sha: sha, sourceId: sourceId),
            filename: item.filename,
            fileURL: fileURL
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }
        
        let delegate = progressHandler.map { UploadProgressDelegate(onProgress: $0) }
        let (data, response) = try await uploadSession.upload(for: request, fromFile: bodyURL, delegate: delegate)
        return try parseUploadResponse(data: data, response: response, usedStreamEndpoint: false)
    }
    
    /// Builds the multipart body in a temp file, copying the source in 4 MB chunks (constant RAM).
    private func writeMultipartBody(boundary: String, fields: [(String, String)], filename: String, fileURL: URL) throws -> URL {
        try FileManager.default.createDirectory(at: uploadTempDir, withIntermediateDirectories: true)
        let bodyURL = uploadTempDir.appendingPathComponent("synaps_upload_\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw URLError(.cannotCreateFile)
        }
        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            
            var header = ""
            for (k, v) in fields {
                header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
            }
            // A quote or newline in the part header's filename would break the multipart framing
            // (the real name travels in original_filename).
            let safeName = filename.map { "\"\r\n".contains($0) ? "_" : String($0) }.joined()
            header += "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
            try output.write(contentsOf: Data(header.utf8))
            
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { try input.read(upToCount: HashEngine.defaultChunkSize) }
                guard let data = chunk, !data.isEmpty else { break }
                try output.write(contentsOf: data)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
        return bodyURL
    }
    
    private func parseUploadResponse(data: Data, response: URLResponse, usedStreamEndpoint: Bool) throws -> IngestUploadResult {
        let http = try checkedHTTP(response)
        try Self.requireSuccess(http, data)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String, status == "success" else {
            throw NASClientError.httpStatus(http.statusCode, Self.errorDetail(from: data) ?? "Upload rejected by server")
        }
        return IngestUploadResult(
            status: status,
            sha256: json["sha256"] as? String,
            canonicalPath: json["canonical_path"] as? String,
            mirrorPath: json["mirror_path"] as? String,
            usedStreamEndpoint: usedStreamEndpoint
        )
    }
    
    // MARK: - Albums
    
    public func syncAlbums(sourceId: String, albumName: String, originalPaths: [String]) async throws {
        var req = try makeRequest(path: "/api/v2/ingest/albums", method: "POST", timeout: 60)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(AlbumSyncPayload(source_id: sourceId, album_name: albumName, original_paths: originalPaths))
        let (data, response) = try await apiSession.data(for: req)
        let http = try checkedHTTP(response)
        try Self.requireSuccess(http, data)
    }
    
    // MARK: - Browse
    
    public func browseDirectory(path: String = "", page: Int = 1, perPage: Int = 1000) async throws -> NASBrowseResponse {
        var queryItems = [
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "per_page", value: "\(min(max(1, perPage), 1000))")
        ]
        if !path.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: path))
        }
        let request = try makeRequest(path: "/api/finder/browse", queryItems: queryItems, timeout: 30)
        
        // One retry with backoff in case the backend was restarting or momentarily busy
        return try await withRetries(maxAttempts: 2) {
            let (data, response) = try await self.apiSession.data(for: request)
            let http = try self.checkedHTTP(response)
            if http.statusCode == 404 {
                return NASBrowseResponse(current_path: path, folders: [], files: [], total_folders: 0, total_files: 0, page: page, per_page: perPage)
            }
            try Self.requireSuccess(http, data)
            return try JSONDecoder().decode(NASBrowseResponse.self, from: data)
        }
    }
    
    /// Returns every file of a NAS directory, fetching pages 2...n after `firstPage` (fetched here
    /// if not supplied). Each page makes the NAS re-list the directory, so pages are as large as
    /// the API allows and the first page is never fetched twice.
    public func browseAllDirectoryFiles(path: String, firstPage: NASBrowseResponse? = nil) async throws -> [NASFileItem] {
        let first: NASBrowseResponse
        if let firstPage = firstPage {
            first = firstPage
        } else {
            first = try await browseDirectory(path: path, page: 1, perPage: 1000)
        }
        var allFiles = first.files
        let perPage = first.per_page > 0 ? first.per_page : 1000
        var page = max(1, first.page) + 1
        
        while allFiles.count < first.total_files && page <= 500 { // Safety limit: 500 pages
            try Task.checkCancellation()
            let resp = try await browseDirectory(path: path, page: page, perPage: perPage)
            if resp.files.isEmpty {
                break
            }
            allFiles.append(contentsOf: resp.files)
            if resp.files.count < perPage {
                break
            }
            page += 1
        }
        
        return allFiles
    }
    
    // MARK: - Download
    
    /// Downloads a NAS file to `destinationURL`, or to "name (1).ext", "name (2).ext", ... when that
    /// name is taken (an existing file is never replaced). Returns the URL actually written.
    public func downloadFile(relativePath: String, destinationURL: URL) async throws -> URL {
        let request = try makeRequest(
            path: "/api/finder/download",
            queryItems: [URLQueryItem(name: "path", value: relativePath)],
            timeout: 120
        )
        let (tempUrl, response) = try await downloadSession.download(for: request)
        defer { try? FileManager.default.removeItem(at: tempUrl) }
        let http = try checkedHTTP(response)
        guard http.statusCode == 200 else {
            throw NASClientError.httpStatus(http.statusCode, nil)
        }
        return try FileManager.default.moveItemToUniqueURL(at: tempUrl, preferred: destinationURL)
    }
}

/// Forwards upload progress of a single task (per-task delegate of the async upload API).
private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Int64, Int64) -> Void
    
    init(onProgress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent, totalBytesExpectedToSend)
    }
}
