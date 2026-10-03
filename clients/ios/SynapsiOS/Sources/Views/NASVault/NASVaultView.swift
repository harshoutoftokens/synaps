import SwiftUI

public struct NASVaultView: View {
    @StateObject private var viewModel = NASVaultViewModel()
    @State private var previewFile: NASFileItem? = nil
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search & Breadcrumb Bar
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Search NAS files...", text: $viewModel.searchQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(UIColor.tertiarySystemBackground))
                    .cornerRadius(10)
                    
                    if !viewModel.pathHistory.isEmpty {
                        HStack {
                            Button {
                                viewModel.navigateBack()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.left")
                                    Text("Back")
                                }
                                .font(.system(size: 13, weight: .semibold))
                            }
                            
                            Spacer()
                            
                            Text(viewModel.currentPath.isEmpty ? "Root" : viewModel.currentPath)
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(UIColor.secondarySystemBackground))
                
                if viewModel.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading NAS Vault...")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = viewModel.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.icloud")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                        Button("Retry") {
                            viewModel.refresh()
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        // Folders section
                        if !viewModel.filteredFolders.isEmpty {
                            Section("Folders (\(viewModel.filteredFolders.count))") {
                                ForEach(viewModel.filteredFolders) { folder in
                                    Button {
                                        viewModel.navigateToFolder(folder)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: "folder.fill")
                                                .foregroundColor(.blue)
                                                .font(.system(size: 20))
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(folder.name)
                                                    .font(.system(size: 15, weight: .medium))
                                                    .foregroundColor(.primary)
                                                if let count = folder.children_count {
                                                    Text("\(count) items")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                            Spacer()
                                            Image(systemName: "chevron.right")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                        
                        // Files section
                        if !viewModel.filteredFiles.isEmpty {
                            Section("Files (\(viewModel.filteredFiles.count))") {
                                ForEach(viewModel.filteredFiles) { file in
                                    HStack(spacing: 12) {
                                        if file.isImageOrVideo, let thumbUrl = NASClient.shared.thumbnailURL(for: file.path) {
                                            AsyncImage(url: thumbUrl) { phase in
                                                switch phase {
                                                case .success(let image):
                                                    image.resizable().aspectRatio(contentMode: .fill)
                                                default:
                                                    Rectangle().fill(Color.gray.opacity(0.2))
                                                        .overlay(Image(systemName: file.isImageOrVideo ? "photo" : "doc.fill").foregroundColor(.secondary))
                                                }
                                            }
                                            .frame(width: 44, height: 44)
                                            .cornerRadius(6)
                                        } else {
                                            Image(systemName: file.isImageOrVideo ? "photo" : "doc.fill")
                                                .font(.system(size: 22))
                                                .foregroundColor(.accentColor)
                                                .frame(width: 44, height: 44)
                                        }
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(file.name)
                                                .font(.system(size: 14, weight: .medium))
                                                .lineLimit(1)
                                            HStack(spacing: 6) {
                                                Text(file.size_human ?? "")
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                                if let mod = file.modified {
                                                    Text("•")
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                    Text(mod.prefix(10))
                                                        .font(.caption)
                                                        .foregroundColor(.secondary)
                                                }
                                            }
                                        }
                                        
                                        Spacer()
                                        
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.green)
                                            .font(.system(size: 16))
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("NAS Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}
