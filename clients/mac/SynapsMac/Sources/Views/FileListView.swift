import SwiftUI
import AppKit

public struct FileListView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var sortOrder = [KeyPathComparator(\SynapsFileItem.modifiedAt, order: .reverse)]
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short
        return df
    }()
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header stats & navigation
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
                
                let uncommitted = viewModel.filteredItems.filter { $0.syncStatus == .uncommitted }.count
                let committed = viewModel.filteredItems.filter { $0.syncStatus == .committed }.count
                
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("\(committed) committed")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                        Text("\(uncommitted) uncommitted")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.red)
                    }
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
                    Text("Scanning files and checking cache...")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if viewModel.filteredItems.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No files in this folder")
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                List(viewModel.filteredItems) { item in
                    let isSelected = viewModel.selectedItemIds.contains(item.id)
                    HStack(spacing: 12) {
                        // File Icon with Badge
                        ZStack(alignment: .bottomTrailing) {
                            fileIcon(for: item.originalPath, isDirectory: item.isDirectory)
                                .frame(width: 32, height: 32)
                            
                            FileBadgeView(status: item.syncStatus, size: 14)
                                .offset(x: 4, y: 4)
                        }
                        .frame(width: 36, height: 36)
                        
                        // Filename & path
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.filename)
                                .font(.body)
                                .fontWeight(isSelected ? .semibold : .regular)
                                .foregroundColor(isSelected ? .accentColor : .primary)
                                .lineLimit(1)
                                .textSelection(.disabled)
                            
                            HStack(spacing: 8) {
                                Text(item.formattedSize)
                                Text("•")
                                Text(dateFormatter.string(from: item.modifiedAt))
                                if let sha = item.sha256 {
                                    Text("•")
                                    Text("SHA: \(sha.prefix(8))...")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        // Status Pill
                        HStack(spacing: 6) {
                            Image(systemName: item.syncStatus.iconSystemName)
                                .foregroundColor(item.syncStatus.color)
                            Text(item.syncStatus.labelText)
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(item.syncStatus.color)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(item.syncStatus.color.opacity(0.12))
                        .cornerRadius(12)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
                    .cornerRadius(6)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        let flags = NSEvent.modifierFlags
                        viewModel.handleItemClick(
                            item,
                            commandKey: flags.contains(.command),
                            shiftKey: flags.contains(.shift),
                            onDoubleClick: {
                                if item.isDirectory {
                                    viewModel.navigateIntoFolder(path: item.originalPath, title: item.filename, sourceId: item.sourceId)
                                } else {
                                    NSWorkspace.shared.open(URL(fileURLWithPath: item.originalPath))
                                }
                            }
                        )
                    }
                    .contextMenu {
                        if !item.isDirectory {
                            Button("Quick Look") {
                                if !viewModel.selectedItemIds.contains(item.id) {
                                    viewModel.handleItemClick(item)
                                }
                                viewModel.toggleQuickLook()
                            }
                        }
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(item.originalPath, inFileViewerRootedAtPath: "")
                        }
                        if let sha = item.sha256 {
                            Button("Copy SHA-256") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(sha, forType: .string)
                            }
                        }
                        if !viewModel.selectedItemIds.isEmpty && (viewModel.selectedItemIds.contains(item.id) || viewModel.selectedItemIds.count > 1) {
                            Button("Sync Selected (\(viewModel.selectedItemIds.count)) to NAS") {
                                viewModel.syncSelectedItems()
                            }
                        } else if item.syncStatus != .committed {
                            Button("Sync to NAS") {
                                viewModel.syncItem(item)
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
    }
    
    private func fileIcon(for path: String, isDirectory: Bool) -> Image {
        if isDirectory {
            return Image(systemName: "folder.fill")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp":
            return Image(systemName: "photo.fill")
        case "mov", "mp4", "m4v":
            return Image(systemName: "film.fill")
        case "pdf":
            return Image(systemName: "doc.richtext.fill")
        case "zip", "tar", "gz":
            return Image(systemName: "doc.zipper")
        case "dmg":
            return Image(systemName: "opticaldiscdrive.fill")
        default:
            return Image(systemName: "doc.fill")
        }
    }
}
