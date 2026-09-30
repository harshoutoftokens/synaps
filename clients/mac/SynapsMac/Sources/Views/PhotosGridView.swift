import SwiftUI
import AppKit

public struct PhotosGridView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var gridSize: CGFloat = 130
    
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: gridSize, maximum: gridSize + 40), spacing: 12, alignment: .top)]
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Controls bar (Navigation, Zoom slider & stats)
            HStack(spacing: 12) {
                if !viewModel.navigationHistory.isEmpty {
                    Button {
                        viewModel.navigateBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                            Text("Back")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                
                Text("\(viewModel.filteredItems.count) \(viewModel.selectedSidebarItem?.isPhone == true ? "Photos & Videos" : "items")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Zoom slider
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Slider(value: $gridSize, in: 80...240)
                        .frame(width: 100)
                    
                    Image(systemName: "square.grid.2x2")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            
            Divider()
            
            if viewModel.isLoading {
                Spacer()
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading...")
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if viewModel.filteredItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Items Found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(viewModel.filteredItems) { item in
                            PhotoThumbnailCell(item: item, size: gridSize) {
                                if item.isDirectory {
                                    viewModel.navigateIntoFolder(path: item.originalPath, title: item.filename, sourceId: item.sourceId)
                                } else {
                                    let url = URL(fileURLWithPath: item.originalPath)
                                    if FileManager.default.fileExists(atPath: item.originalPath) {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
    }
}

public struct PhotoThumbnailCell: View {
    public let item: SynapsFileItem
    public let size: CGFloat
    public var onDoubleClick: (() -> Void)? = nil
    @State private var nsImage: NSImage?
    @State private var isHovered = false
    
    private var isDirectoryOrDoc: Bool {
        item.isDirectory || !item.isImageOrVideo
    }
    
    public var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // Background & Thumbnail / Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                    
                    if let img = nsImage {
                        if isDirectoryOrDoc {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(size * 0.14)
                                .frame(width: size, height: size)
                        } else {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: size, height: size)
                                .clipped()
                                .cornerRadius(10)
                        }
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder.fill" : (item.isLivePhotoVideo ? "video.fill" : (item.isImageOrVideo ? "photo" : "doc.fill")))
                                .font(.system(size: size * 0.3))
                                .foregroundColor(item.isDirectory ? .accentColor : .secondary.opacity(0.7))
                        }
                        .frame(width: size, height: size)
                    }
                }
                .frame(width: size, height: size)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHovered ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isHovered ? 2 : 1)
                )
                
                // Favorite Badge (Top Left)
                if item.isFavorite {
                    VStack {
                        HStack {
                            Image(systemName: "heart.fill")
                                .foregroundColor(.pink)
                                .font(.system(size: 11))
                                .padding(4)
                                .background(Circle().fill(Color.black.opacity(0.6)))
                                .padding(6)
                            Spacer()
                        }
                        Spacer()
                    }
                    .frame(width: size, height: size)
                }
                
                // Video indicator (Top Right)
                if item.isLivePhotoVideo || item.filename.lowercased().hasSuffix(".mov") || item.filename.lowercased().hasSuffix(".mp4") {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "play.circle.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 13))
                                .padding(6)
                        }
                        Spacer()
                    }
                    .frame(width: size, height: size)
                }
                
                // Git-for-Files Badge (Bottom Right)
                FileBadgeView(status: item.syncStatus, size: max(16, size * 0.16))
                    .padding(6)
            }
            
            // Item / Folder Name Label
            Text(item.filename)
                .font(.system(size: max(10, min(12, size * 0.085))))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundColor(isHovered ? .accentColor : .primary)
                .frame(width: size + 16, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onDoubleClick?()
        }
        .onHover { isHovered = $0 }
        .onAppear {
            loadThumbnail()
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(item.originalPath, inFileViewerRootedAtPath: "")
            }
            if let sha = item.sha256 {
                Button("Copy SHA-256") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                }
            }
            if item.syncStatus == .uncommitted {
                Button("Sync to NAS Vault") {
                    Task {
                        _ = try? await NASClient.shared.uploadFile(item: item, sourceId: item.sourceId)
                    }
                }
            }
        }
    }
    
    private func loadThumbnail() {
        guard nsImage == nil else { return }
        ThumbnailLoader.shared.loadThumbnail(for: item.originalPath, targetSize: size) { image in
            self.nsImage = image
        }
    }
}
