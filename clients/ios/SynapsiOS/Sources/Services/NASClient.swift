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
}

public struct IngestCheckBatchResponse: Codable, Sendable {
    public let source_id: String?
    public let status: String?
    public let total_checked: Int?
    public let dedup_linked: Int?
    public let need_upload: Int?
    public let results: [IngestCheckItemResult]
}

public final class NASClient: @unchecked Sendable {
    public static let shared = NASClient()
    private var activeBaseUrl: String = "http://192.168.0.105:8000"
    private let lock = NSLock()
    
    private init() {
        let cfg = SynapsConfig.load()
        self.activeBaseUrl = cfg.nasUrl
    }
    
    public func setBaseUrl(_ url: String) {
        lock.lock()
        defer { lock.unlock() }
        self.activeBaseUrl = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    public func getBaseUrl() -> String {
        lock.lock()
        defer { lock.unlock() }
        return activeBaseUrl
    }
    
    public func checkHealth() async -> Bool {
        let currentUrl = getBaseUrl()
        let rawCandidates = [
            currentUrl,
            SynapsConfig.load().nasUrl,
            "http://192.168.0.105:8000",
            "http://homecloud1.local:8000",
            "http://192.168.0.101:8000",
            "http://localhost:8000"
        ]
        
        var seen = Set<String>()
        var candidates: [String] = []
        for c in rawCandidates {
            let trimmed = c.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                candidates.append(trimmed)
            }
        }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.5
        config.timeoutIntervalForResource = 2.5
        let session = URLSession(configuration: config)
        
        let foundUrl: String? = await withTaskGroup(of: String?.self) { group in
            for candidate in candidates {
                group.addTask {
                    for path in ["/api/health", "/health"] {
                        guard let url = URL(string: "\(candidate)\(path)") else { continue }
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 2.5
                        do {
                            let (data, response) = try await session.data(for: req)
                            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   json["status"] as? String == "ok" {
                                    return candidate
                                }
                            }
                        } catch {
                            // Candidate unreachable
                        }
                    }
                    return nil
                }
            }
            
            for await result in group {
                if let candidate = result {
                    group.cancelAll()
                    return candidate
                }
            }
            return nil
        }
        
        if let found = foundUrl {
            setBaseUrl(found)
            var cfg = SynapsConfig.load()
            if cfg.nasUrl != found {
                cfg.nasUrl = found
                cfg.save()
            }
            return true
        }
        
        return false
    }
    
    public func batchPreCheck(
        sourceId: String,
        friendlyName: String,
        items: [SynapsMediaItem]
    ) async throws -> IngestCheckBatchResponse {
        let baseUrl = getBaseUrl()
        guard let url = URL(string: "\(baseUrl)/api/v2/ingest/check") else {
            throw URLError(.badURL)
        }
        
        let dateFormatter = ISO8601DateFormatter()
        let filePayloads = items.compactMap { item -> IngestCheckFilePayload? in
            guard let sha = item.sha256 else { return nil }
            return IngestCheckFilePayload(
                original_path: item.originalPath,
                original_filename: item.filename,
                file_size: item.fileSize,
                source_location: "Photos",
                source_modified_at: dateFormatter.string(from: item.modifiedAt),
                client_sha256: sha,
                is_favorite: item.isFavorite
            )
        }
        
        let batchReq = IngestCheckBatchRequest(
            source: IngestSourcePayload(
                id: sourceId,
                friendly_name: friendlyName,
                platform: "ios",
                volume_identifier: nil
            ),
            files: filePayloads
        )
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(batchReq)
        request.timeoutInterval = 60
        
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        
        return try JSONDecoder().decode(IngestCheckBatchResponse.self, from: data)
    }
    
    public func uploadMediaFile(
        fileURL: URL,
        item: SynapsMediaItem,
        sourceId: String
    ) async throws -> Bool {
        let baseUrl = getBaseUrl()
        guard let url = URL(string: "\(baseUrl)/api/v2/ingest/upload") else {
            throw URLError(.badURL)
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300
        
        let dateFormatter = ISO8601DateFormatter()
        let fields: [String: String] = [
            "source_id": sourceId,
            "original_path": item.originalPath,
            "original_filename": item.filename,
            "source_location": "Photos",
            "client_sha256": item.sha256 ?? "",
            "source_created_at": dateFormatter.string(from: item.createdAt),
            "source_modified_at": dateFormatter.string(from: item.modifiedAt),
            "is_favorite": item.isFavorite ? "true" : "false"
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempUploadFile = tempDir.appendingPathComponent("synaps_ios_upload_\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tempUploadFile) }
        
        FileManager.default.createFile(atPath: tempUploadFile.path, contents: nil)
        guard let outputStream = OutputStream(url: tempUploadFile, append: true) else {
            throw URLError(.cannotCreateFile)
        }
        outputStream.open()
        
        // Write header fields
        for (k, v) in fields {
            let part = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
            if let d = part.data(using: .utf8) {
                _ = d.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: d.count) }
            }
        }
        
        // Write file header
        let fileHeader = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(item.filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        if let hd = fileHeader.data(using: .utf8) {
            _ = hd.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: hd.count) }
        }
        
        // Stream file contents in 1MB chunks to stay light on RAM
        guard let sourceHandle = try? FileHandle(forReadingFrom: fileURL) else {
            outputStream.close()
            throw URLError(.fileDoesNotExist)
        }
        
        while true {
            var chunkEmpty = false
            autoreleasepool {
                let chunk = sourceHandle.readData(ofLength: 1024 * 1024)
                if chunk.isEmpty {
                    chunkEmpty = true
                } else {
                    _ = chunk.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: chunk.count) }
                }
            }
            if chunkEmpty { break }
        }
        try? sourceHandle.close()
        
        let closing = "\r\n--\(boundary)--\r\n"
        if let cd = closing.data(using: .utf8) {
            _ = cd.withUnsafeBytes { outputStream.write($0.bindMemory(to: UInt8.self).baseAddress!, maxLength: cd.count) }
        }
        outputStream.close()
        
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: tempUploadFile)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           json["status"] as? String == "success" {
            return true
        }
        return false
    }
    
    public func browseDirectory(path: String = "", page: Int = 1, perPage: Int = 200) async throws -> NASBrowseResponse {
        let baseUrl = getBaseUrl()
        var components = URLComponents(string: "\(baseUrl)/api/finder/browse")
        var queryItems = [
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "per_page", value: "\(min(max(1, perPage), 500))")
        ]
        if !path.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: path))
        }
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        if http.statusCode == 404 {
            return NASBrowseResponse(current_path: path, folders: [], files: [], total_folders: 0, total_files: 0, page: page, per_page: perPage)
        }
        guard http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(NASBrowseResponse.self, from: data)
    }
    
    public func thumbnailURL(for relativePath: String) -> URL? {
        let baseUrl = getBaseUrl()
        var components = URLComponents(string: "\(baseUrl)/api/finder/thumbnail")
        components?.queryItems = [
            URLQueryItem(name: "path", value: relativePath),
            URLQueryItem(name: "size", value: "300")
        ]
        return components?.url
    }
}
