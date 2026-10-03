import SwiftUI
import Combine

@MainActor
public final class NASVaultViewModel: ObservableObject {
    @Published public var currentPath: String = ""
    @Published public var pathHistory: [String] = []
    @Published public var folders: [NASFolderItem] = []
    @Published public var files: [NASFileItem] = []
    @Published public var isLoading: Bool = false
    @Published public var errorMessage: String? = nil
    @Published public var searchQuery: String = ""
    
    public init() {
        Task {
            await loadDirectory(path: "")
        }
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
    
    public func loadDirectory(path: String) async {
        isLoading = true
        errorMessage = nil
        
        do {
            let resp = try await NASClient.shared.browseDirectory(path: path, page: 1, perPage: 500)
            self.currentPath = resp.current_path
            self.folders = resp.folders
            self.files = resp.files
        } catch {
            self.errorMessage = "Failed to load NAS folder: \(error.localizedDescription)"
        }
        
        isLoading = false
    }
    
    public func navigateToFolder(_ folder: NASFolderItem) {
        pathHistory.append(currentPath)
        Task {
            await loadDirectory(path: folder.path)
        }
    }
    
    public func navigateBack() {
        guard let prev = pathHistory.popLast() else { return }
        Task {
            await loadDirectory(path: prev)
        }
    }
    
    public func refresh() {
        Task {
            await loadDirectory(path: currentPath)
        }
    }
}
