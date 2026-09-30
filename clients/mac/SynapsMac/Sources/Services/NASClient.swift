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
}

public struct IngestCheckBatchResponse: Codable {
    public let status: String
    public let total_checked: Int
    public let dedup_count: Int
    public let need_upload_count: Int
    public let results: [IngestCheckItemResult]
}

public struct AlbumSyncPayload: Codable {
    public let source_id: String
    public let album_name: String
    public let original_paths: [String]
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
        let candidates = [
            activeBaseUrl,
            "http://192.168.0.101:8000",
            "http://homecloud1.local:8000",
            "http://192.168.0.105:8000",
            "http://localhost:8000"
        ]
        
        for candidate in candidates {
            guard let url = URL(string: "\(candidate)/health") else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 1.5
            do {
                let (data, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["status"] as? String == "ok" {
                        if candidate != activeBaseUrl {
                            self.activeBaseUrl = candidate
                            var cfg = SynapsConfig.load()
                            cfg.nasUrl = candidate
                            cfg.save()
                        }
                        return true
                    }
                }
            } catch {
                continue
            }
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
}
