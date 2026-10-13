import SwiftUI
import Combine

@MainActor
public final class NASVaultViewModel: ObservableObject {
    @Published public private(set) var currentPath: String = ""
    @Published public private(set) var folders: [NASFolderItem] = []
    @Published public private(set) var files: [NASFileItem] = []
    @Published public private(set) var totalFiles: Int = 0
    @Published public private(set) var isLoading: Bool = false
    @Published public private(set) var isLoadingMore: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var searchQuery: String = ""
    
    private static let pageSize = 200
    private var page = 1
    private var loadTask: Task<Void, Never>?
    private var hasLoaded = false
    
    public init() {}
    
    public var canGoBack: Bool {
        !currentPath.isEmpty
    }
    
    public var displayPath: String {
        currentPath.isEmpty ? "Root" : currentPath
    }
    
    /// /api/finder/browse paginates files (folders are always complete).
    public var hasMoreFiles: Bool {
        files.count < totalFiles
    }
    
    public var filteredFiles: [NASFileItem] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return files
        }
        return files.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }
    
    public var filteredFolders: [NASFolderItem] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return folders
        }
        return folders.filter { $0.name.localizedCaseInsensitiveContains(searchQuery) }
    }
    
    public func loadIfNeeded() {
        guard !hasLoaded else { return }
        hasLoaded = true
        #if DEBUG
        load(path: UserDefaults.standard.string(forKey: "SynapsVaultPath") ?? "") // simulator test hook
        #else
        load(path: "")
        #endif
    }
    
    /// Loads the first page of `path`, cancelling any load still in flight so a slow earlier
    /// response can't overwrite the folder the user navigated to last.
    public func load(path: String) {
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil
        loadTask = Task { [weak self] in
            do {
                let resp = try await NASClient.shared.browseDirectory(path: path, page: 1, perPage: Self.pageSize)
                guard let self, !Task.isCancelled else { return }
                if self.currentPath != resp.normalizedPath {
                    self.searchQuery = ""
                }
                self.currentPath = resp.normalizedPath
                self.folders = resp.folders
                self.files = resp.files
                self.totalFiles = resp.total_files
                self.page = 1
                self.isLoading = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .cancelled { return }
                self.errorMessage = Self.describe(error)
                self.isLoading = false
            }
        }
    }
    
    public func loadMoreIfNeeded(currentFile: NASFileItem) {
        guard hasMoreFiles, !isLoading, !isLoadingMore, currentFile.id == files.last?.id else { return }
        isLoadingMore = true
        let path = currentPath
        let nextPage = page + 1
        Task { [weak self] in
            let resp = try? await NASClient.shared.browseDirectory(path: path, page: nextPage, perPage: Self.pageSize)
            guard let self else { return }
            self.isLoadingMore = false
            guard let resp, self.currentPath == path else { return }
            let known = Set(self.files.map { $0.path })
            self.files.append(contentsOf: resp.files.filter { !known.contains($0.path) })
            self.totalFiles = resp.total_files
            self.page = nextPage
        }
    }
    
    public func navigateToFolder(_ folder: NASFolderItem) {
        load(path: folder.path)
    }
    
    public func navigateBack() {
        guard canGoBack else { return }
        load(path: (currentPath as NSString).deletingLastPathComponent)
    }
    
    public func refresh() {
        load(path: currentPath)
    }
    
    private static func describe(_ error: Error) -> String {
        if let nasError = error as? NASError, nasError == .unauthorized {
            return "The NAS requires a valid API token. Add it in Settings → API Token."
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cannotConnectToHost, .timedOut, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost:
                return "Cannot reach the NAS at \(NASClient.shared.getBaseUrl()). Check that you're on your home Wi-Fi."
            default:
                break
            }
        }
        return "Failed to load NAS folder: \(error.localizedDescription)"
    }
}
