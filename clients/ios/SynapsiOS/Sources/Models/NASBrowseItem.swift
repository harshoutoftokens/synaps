import Foundation

public struct NASFolderItem: Codable, Identifiable, Sendable {
    public var id: String { path }
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

public struct NASFileItem: Codable, Identifiable, Sendable {
    public var id: String { path }
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
    
    public var isImageOrVideo: Bool {
        // /api/finder/browse classifies files itself ("image"/"video"/"document"/"other").
        if let kind = file_type, kind == "image" || kind == "video" {
            return true
        }
        // The backend sends the extension with its leading dot (".jpg"); strip it before matching.
        var ext = (`extension` ?? (name as NSString).pathExtension).lowercased()
        if ext.hasPrefix(".") {
            ext.removeFirst()
        }
        let mediaExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "dng", "mov", "mp4", "m4v"]
        return mediaExtensions.contains(ext)
    }
    
    public var isVideo: Bool {
        if file_type == "video" { return true }
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mov", "mp4", "m4v"].contains(ext)
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
    
    /// The backend reports the storage root as "/"; normalize it to "" for path math and display.
    public var normalizedPath: String {
        current_path == "/" ? "" : current_path
    }
}
