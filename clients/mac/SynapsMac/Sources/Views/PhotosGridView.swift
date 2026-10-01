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
            if viewModel.isPicturesSection {
                picturesContent
            } else {
                standardFolderContent
            }
        }
    }
    
    // MARK: - Pictures (iPhone Import) View
    @ViewBuilder
    private var picturesContent: some View {
        if viewModel.phoneManager.connectedDevice == nil {
            noPhoneConnectedView
        } else if viewModel.phoneManager.isDeviceLocked {
            deviceLockedView
        } else {
            VStack(spacing: 0) {
                importControlsBar
                
                Divider()
                
                if viewModel.isLoading {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Reading photos from iPhone...")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else if viewModel.filteredItems.isEmpty {
                    Spacer()
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Photos Found on iPhone")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(viewModel.filteredItems) { item in
                                PhotoThumbnailCell(
                                    item: item,
                                    size: gridSize,
                                    isPicturesSection: true,
                                    isSelected: viewModel.selectedItemIds.contains(item.id),
                                    onToggleSelect: {
                                        viewModel.toggleSelection(id: item.id)
                                    },
                                    onDoubleClick: {
                                        viewModel.toggleSelection(id: item.id)
                                    }
                                )
                            }
                        }
                        .padding(14)
                    }
                }
            }
        }
    }
    
    private var noPhoneConnectedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "cable.connector.horizontal")
                .font(.system(size: 52))
                .foregroundColor(.secondary.opacity(0.8))
            Text("No iPhone Connected")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Connect your iPhone to this Mac via USB cable to browse and import photos.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var deviceLockedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundColor(.orange)
            Text("iPhone is Locked")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Unlock your iPhone with your passcode or Face ID and tap \"Trust This Computer\" to view photos.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button {
                viewModel.phoneManager.checkDeviceStatus()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                    Text("Check Again")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var importControlsBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.filteredItems.count) Photos & Videos on iPhone")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    if !viewModel.selectedItemIds.isEmpty {
                        Text("\(viewModel.selectedItemIds.count) of \(viewModel.filteredItems.count) selected")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                // Zoom slider
                zoomSlider
                
                if !viewModel.filteredItems.isEmpty {
                    Button(viewModel.selectedItemIds.count == viewModel.filteredItems.count ? "Deselect All" : "Select All") {
                        if viewModel.selectedItemIds.count == viewModel.filteredItems.count {
                            viewModel.deselectAll()
                        } else {
                            viewModel.selectAll()
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    
                    Button {
                        viewModel.importSelectedItems()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import Selected (\(viewModel.selectedItemIds.count))")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.selectedItemIds.isEmpty || viewModel.phoneManager.isImporting)
                    
                    Button {
                        viewModel.importAllItems()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.down.circle.fill")
                            Text("Import All")
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.filteredItems.isEmpty || viewModel.phoneManager.isImporting)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            
            if viewModel.phoneManager.isImporting {
                VStack(spacing: 4) {
                    ProgressView(value: viewModel.phoneManager.importProgress)
                        .progressViewStyle(.linear)
                        .padding(.horizontal, 16)
                    Text(viewModel.phoneManager.importStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.08))
            } else if !viewModel.phoneManager.importStatusMessage.isEmpty {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text(viewModel.phoneManager.importStatusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.08))
            }
        }
    }
    
    // MARK: - Standard Folder Content
    private var standardFolderContent: some View {
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
                
                Text("\(viewModel.filteredItems.count) items")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                zoomSlider
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
                    ZStack(alignment: .topLeading) {
                        // Background canvas to capture empty space clicks
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.clearSelection()
                            }
                        
                        if viewModel.sortField == .kind {
                            VStack(alignment: .leading, spacing: 20) {
                                ForEach(viewModel.groupedItemsByKind) { group in
                                    VStack(alignment: .leading, spacing: 10) {
                                        kindSectionHeader(for: group)
                                            .padding(.horizontal, 16)
                                            .padding(.top, 4)
                                        
                                        if !viewModel.isKindCollapsed(group.kind.rawValue) {
                                            LazyVGrid(columns: columns, spacing: 14) {
                                                ForEach(group.items) { item in
                                                    photoThumbnailCell(for: item)
                                                }
                                            }
                                            .padding(.horizontal, 16)
                                        }
                                    }
                                }
                            }
                            .padding(.vertical, 12)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            LazyVGrid(columns: columns, spacing: 14) {
                                ForEach(viewModel.filteredItems) { item in
                                    photoThumbnailCell(for: item)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 600, alignment: .topLeading)
                }
                .background(
                    Color(nsColor: .windowBackgroundColor)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.clearSelection()
                        }
                )
            }
        }
    }
    
    @ViewBuilder
    private func kindSectionHeader(for group: AppViewModel.FileGroup) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                viewModel.toggleKindCollapsed(group.kind.rawValue)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                    .rotationEffect(.degrees(viewModel.isKindCollapsed(group.kind.rawValue) ? 0 : 90))
                    .frame(width: 14)
                
                Text(group.kind.rawValue)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                
                Text("\(group.items.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(Color(nsColor: .quaternaryLabelColor))
                    )
                
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func photoThumbnailCell(for item: SynapsFileItem) -> some View {
        PhotoThumbnailCell(
            item: item,
            size: gridSize,
            isPicturesSection: false,
            isNASSection: viewModel.isNASSection,
            isSelected: viewModel.selectedItemIds.contains(item.id),
            onToggleSelect: {
                let flags = NSEvent.modifierFlags
                viewModel.handleItemClick(
                    item,
                    commandKey: flags.contains(.command),
                    shiftKey: flags.contains(.shift),
                    onDoubleClick: {
                        if item.isDirectory {
                            viewModel.navigateIntoFolder(path: item.originalPath, title: item.filename, sourceId: item.sourceId)
                        } else if viewModel.isNASSection {
                            viewModel.downloadNASItem(item)
                        } else {
                            let url = URL(fileURLWithPath: item.originalPath)
                            if FileManager.default.fileExists(atPath: item.originalPath) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                )
            },
            onSync: {
                if !viewModel.selectedItemIds.isEmpty && (viewModel.selectedItemIds.contains(item.id) || viewModel.selectedItemIds.count > 1) {
                    viewModel.syncSelectedItems()
                } else {
                    viewModel.syncItem(item)
                }
            },
            onDownload: {
                viewModel.downloadNASItem(item)
            },
            selectedCount: viewModel.selectedItemIds.count
        )
    }
    
    private var zoomSlider: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x3")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Slider(value: $gridSize, in: 80...240)
                .frame(width: 90)
            
            Image(systemName: "square.grid.2x2")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

public struct PhotoThumbnailCell: View {
    public let item: SynapsFileItem
    public let size: CGFloat
    public var isPicturesSection: Bool = false
    public var isNASSection: Bool = false
    public var isSelected: Bool = false
    public var onToggleSelect: (() -> Void)? = nil
    public var onDoubleClick: (() -> Void)? = nil
    public var onSync: (() -> Void)? = nil
    public var onDownload: (() -> Void)? = nil
    public var selectedCount: Int = 0
    
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
                        .stroke(
                            isSelected ? Color.accentColor : (isHovered ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.08)),
                            lineWidth: isSelected ? 3 : (isHovered ? 2 : 1)
                        )
                )
                
                // Selection Checkbox for Pictures Section (Top Left)
                if isPicturesSection {
                    VStack {
                        HStack {
                            Button {
                                onToggleSelect?()
                            } label: {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(isSelected ? .accentColor : (isHovered ? .white : .clear))
                                    .font(.system(size: max(16, size * 0.16)))
                                    .background(
                                        Circle()
                                            .fill(isSelected ? Color.clear : (isHovered ? Color.black.opacity(0.4) : Color.clear))
                                    )
                            }
                            .buttonStyle(.plain)
                            .padding(6)
                            Spacer()
                        }
                        Spacer()
                    }
                    .frame(width: size, height: size)
                } else if item.isFavorite {
                    // Favorite Badge (Top Left)
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
                if !isPicturesSection && !isNASSection {
                    FileBadgeView(status: item.syncStatus, size: max(16, size * 0.16))
                        .padding(6)
                }
            }
            
            // Item / Folder Name Label
            Text(item.filename)
                .font(.system(size: max(10, min(12, size * 0.085))))
                .fontWeight(isSelected ? .medium : .regular)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .foregroundColor(isSelected ? .accentColor : (isHovered ? .accentColor : .primary))
                .textSelection(.disabled)
                .frame(width: size + 16, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onToggleSelect?()
        }
        .onHover { isHovered = $0 }
        .onAppear {
            loadThumbnail()
        }
        .onReceive(iPhoneManager.shared.$thumbnailsVersion) { _ in
            if item.originalPath.hasPrefix("iPhone://") && nsImage == nil {
                if let img = iPhoneManager.shared.getThumbnail(for: item.filename) {
                    self.nsImage = img
                }
            }
        }
        .contextMenu {
            if isPicturesSection {
                Button(isSelected ? "Deselect" : "Select") {
                    onToggleSelect?()
                }
            }
            if !item.isDirectory && FileManager.default.fileExists(atPath: item.originalPath) {
                Button("Quick Look") {
                    QuickLookCoordinator.shared.toggleQuickLook(for: [URL(fileURLWithPath: item.originalPath)])
                }
            }
            if FileManager.default.fileExists(atPath: item.originalPath) {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(item.originalPath, inFileViewerRootedAtPath: "")
                }
            }
            if let sha = item.sha256 {
                Button("Copy SHA-256") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                }
            }
            if isNASSection {
                if !item.isDirectory {
                    Button("Download to Mac") {
                        onDownload?()
                    }
                }
            } else {
                if item.syncStatus != .committed && FileManager.default.fileExists(atPath: item.originalPath) {
                    Button(selectedCount > 1 ? "Sync Selected (\(selectedCount)) to NAS" : "Sync to NAS") {
                        onSync?()
                    }
                }
            }
        }
    }
    
    private func loadThumbnail() {
        guard nsImage == nil else { return }
        if item.originalPath.hasPrefix("iPhone://") {
            if let cached = iPhoneManager.shared.getThumbnail(for: item.filename) {
                self.nsImage = cached
            } else {
                iPhoneManager.shared.requestThumbnail(for: item.filename)
            }
        } else if item.originalPath.hasPrefix("nas://") {
            return
        } else {
            ThumbnailLoader.shared.loadThumbnail(for: item.originalPath, targetSize: size) { image in
                self.nsImage = image
            }
        }
    }
}
