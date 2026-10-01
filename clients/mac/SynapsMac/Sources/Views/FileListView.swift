import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                if viewModel.sortField == .kind {
                    List {
                        ForEach(viewModel.groupedItemsByKind) { group in
                            Section(header: kindSectionHeader(for: group)) {
                                if !viewModel.isKindCollapsed(group.kind.rawValue) {
                                    ForEach(group.items) { item in
                                        fileRow(for: item)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(
                        Color(nsColor: .controlBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.clearSelection()
                            }
                    )
                } else {
                    List(viewModel.filteredItems) { item in
                        fileRow(for: item)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .background(
                        Color(nsColor: .controlBackgroundColor)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                viewModel.clearSelection()
                            }
                    )
                }
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
    
    @ViewBuilder
    private func fileRow(for item: SynapsFileItem) -> some View {
        let isSelected = viewModel.selectedItemIds.contains(item.id)
        HStack(spacing: 12) {
            // File Icon with Badge
            ZStack(alignment: .bottomTrailing) {
                fileIcon(for: item.originalPath, isDirectory: item.isDirectory)
                    .frame(width: 32, height: 32)
                
                if !viewModel.isNASSection {
                    FileBadgeView(status: item.syncStatus, size: 14)
                        .offset(x: 4, y: 4)
                }
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
                    if !item.isDirectory {
                        Text(item.formattedSize)
                        Text("•")
                    }
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
            
            // Status Pill (Hide on NAS section)
            if !viewModel.isNASSection {
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
                    } else if viewModel.isNASSection {
                        viewModel.downloadNASItem(item)
                    } else {
                        NSWorkspace.shared.open(URL(fileURLWithPath: item.originalPath))
                    }
                }
            )
        }
        .contextMenu {
            if !item.isDirectory {
                if !item.originalPath.hasPrefix("nas://") {
                    Button("Quick Look") {
                        if !viewModel.selectedItemIds.contains(item.id) {
                            viewModel.handleItemClick(item)
                        }
                        viewModel.toggleQuickLook()
                    }
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
            if viewModel.isNASSection {
                if !item.isDirectory {
                    Button("Download to Mac") {
                        viewModel.downloadNASItem(item)
                    }
                }
            } else {
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
    }
    
    @ViewBuilder
    private func fileIcon(for path: String, isDirectory: Bool) -> some View {
        if isDirectory {
            Image(nsImage: NSWorkspace.shared.icon(for: .folder))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            let ext = (path as NSString).pathExtension.lowercased()
            if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
                Image(nsImage: NSWorkspace.shared.icon(for: utType))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(for: .data))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
    }
}
