import Foundation

public struct IngestCheckFilePayload: Codable {
    public let original_path: String
    public let original_filename: String
    public let file_size: Int64
    public let source_location: String
    public let source_modified_at: String?
    public let client_sha256: String
    public let is_favorite: Bool?
}

public struct IngestSourcePayload: Codable {
    public let id: String
    public let friendly_name: String
    public let platform: String
    public let volume_identifier: String?
}

public struct IngestCheckBatchRequest: Codable {
    public let source: IngestSourcePayload
    public let files: [IngestCheckFilePayload]
}

public struct IngestCheckItemResult: Codable {
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
}

public struct IngestCheckBatchResponse: Codable {
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

public struct AlbumSyncPayload: Codable {
    public let source_id: String
    public let album_name: String
    public let original_paths: [String]
}

public struct NASFolderItem: Codable {
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

public struct NASFileItem: Codable {
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

public struct NASBrowseResponse: Codable {
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

public final class NASClient {
    public static let shared = NASClient()
    private var activeBaseUrl: String = "http://192.168.0.105:8000"
    
    private init() {
        let cfg = SynapsConfig.load()
        self.activeBaseUrl = cfg.nasUrl
    }
    
    public func setBaseUrl(_ url: String) {
        self.activeBaseUrl = url.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    
    public func getBaseUrl() -> String {
        return activeBaseUrl
    }
    
    public func checkHealth() async -> Bool {
        let rawCandidates = [
            activeBaseUrl,
            SynapsConfig.load().nasUrl,
            "http://192.168.0.101:8000",
            "http://homecloud1.local:8000",
            "http://192.168.0.105:8000",
            "http://localhost:8000"
        ]
        
        var seen = Set<String>()
        var uniqueCandidates: [String] = []
        for candidate in rawCandidates {
            let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !trimmed.isEmpty && !seen.contains(trimmed) {
                seen.insert(trimmed)
                uniqueCandidates.append(trimmed)
            }
        }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2.0
        config.timeoutIntervalForResource = 2.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        
        let foundUrl: String? = await withTaskGroup(of: String?.self) { group in
            for candidate in uniqueCandidates {
                group.addTask {
                    for path in ["/api/health", "/health"] {
                        guard let url = URL(string: "\(candidate)\(path)") else { continue }
                        var req = URLRequest(url: url)
                        req.timeoutInterval = 2.0
                        req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
                        do {
                            let (data, response) = try await session.data(for: req)
                            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                   json["status"] as? String == "ok" {
                                    return candidate
                                }
                            }
                        } catch {
                            // Candidate offline or connection failed
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
            if found != self.activeBaseUrl {
                self.activeBaseUrl = found
                var cfg = SynapsConfig.load()
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
        platform: String,
        items: [SynapsFileItem]
    ) async throws -> IngestCheckBatchResponse {
        guard let url = URL(string: "\(activeBaseUrl)/api/v2/ingest/check") else {
            throw URLError(.badURL)
        }
        
        let dateFormatter = ISO8601DateFormatter()
        let filePayloads = items.compactMap { item -> IngestCheckFilePayload? in
            guard let sha = item.sha256 else { return nil }
            return IngestCheckFilePayload(
                original_path: item.originalPath,
                original_filename: item.filename,
                file_size: item.fileSize,
                source_location: item.sourceLocation,
                source_modified_at: dateFormatter.string(from: item.modifiedAt),
                client_sha256: sha,
                is_favorite: item.isFavorite
            )
        }
        
        let batchReq = IngestCheckBatchRequest(
            source: IngestSourcePayload(
                id: sourceId,
                friendly_name: friendlyName,
                platform: platform,
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
    
    public func uploadFile(
        item: SynapsFileItem,
        sourceId: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> Bool {
        guard let url = URL(string: "\(activeBaseUrl)/api/v2/ingest/upload") else {
            throw URLError(.badURL)
        }
        
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        
        let dateFormatter = ISO8601DateFormatter()
        let fields: [String: String] = [
            "source_id": sourceId,
            "original_path": item.originalPath,
            "original_filename": item.filename,
            "source_location": item.sourceLocation,
            "client_sha256": item.sha256 ?? "",
            "source_created_at": dateFormatter.string(from: item.createdAt),
            "source_modified_at": dateFormatter.string(from: item.modifiedAt),
            "is_favorite": item.isFavorite ? "true" : "false"
        ]
        
        let tempDir = FileManager.default.temporaryDirectory
        let tempUploadFile = tempDir.appendingPathComponent("synaps_upload_\(UUID().uuidString).tmp")
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
        
        // Stream file contents from disk to temp file in 1MB chunks (constant 1MB RAM!)
        guard let sourceHandle = FileHandle(forReadingAtPath: item.originalPath) else {
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
    
    public func syncAlbums(sourceId: String, albumName: String, originalPaths: [String]) async throws {
        guard let url = URL(string: "\(activeBaseUrl)/api/v2/ingest/sync-albums") else { return }
        let payload = AlbumSyncPayload(source_id: sourceId, album_name: albumName, original_paths: originalPaths)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(payload)
        _ = try await URLSession.shared.data(for: req)
    }
    
    public func browseDirectory(path: String = "", page: Int = 1, perPage: Int = 1000) async throws -> NASBrowseResponse {
        var components = URLComponents(string: "\(activeBaseUrl)/api/finder/browse")
        var queryItems = [
            URLQueryItem(name: "page", value: "\(max(1, page))"),
            URLQueryItem(name: "per_page", value: "\(min(max(1, perPage), 1000))")
        ]
        if !path.isEmpty {
            queryItems.append(URLQueryItem(name: "path", value: path))
        }
        components?.queryItems = queryItems
        
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25.0
        config.timeoutIntervalForResource = 35.0
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: config)
        
        do {
            let (data, response) = try await session.data(from: url)
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
        } catch {
            // One-time retry after brief delay in case backend was restarting or momentarily busy
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(NASBrowseResponse.self, from: data)
        }
    }
    
    public func browseAllDirectoryFiles(path: String) async throws -> [NASFileItem] {
        var page = 1
        var allFiles: [NASFileItem] = []
        var totalExpected: Int? = nil
        
        while page <= 50 { // Safety limit: up to 50,000 files
            let resp = try await browseDirectory(path: path, page: page, perPage: 1000)
            if resp.files.isEmpty {
                break
            }
            allFiles.append(contentsOf: resp.files)
            if totalExpected == nil {
                totalExpected = resp.total_files
            }
            if allFiles.count >= (totalExpected ?? 0) || resp.files.count < 1000 {
                break
            }
            page += 1
        }
        
        return allFiles
    }
    
    public func downloadFile(relativePath: String, destinationURL: URL) async throws -> Bool {
        var components = URLComponents(string: "\(activeBaseUrl)/api/finder/download")
        components?.queryItems = [URLQueryItem(name: "path", value: relativePath)]
        
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        
        let (tempUrl, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try? FileManager.default.removeItem(at: destinationURL)
        }
        
        try FileManager.default.moveItem(at: tempUrl, to: destinationURL)
        return true
    }
}
