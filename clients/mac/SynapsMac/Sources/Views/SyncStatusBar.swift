import SwiftUI

public struct SyncStatusBar: View {
    @ObservedObject var viewModel: AppViewModel
    public var isGridMode: Bool = true
    @AppStorage("photosGridSize") private var gridSize: Double = 80
    
    public init(viewModel: AppViewModel, isGridMode: Bool = true) {
        self.viewModel = viewModel
        self.isGridMode = isGridMode
    }
    
    public var body: some View {
        HStack(spacing: 16) {
            // Status and Summary
            HStack(spacing: 8) {
                if viewModel.isPicturesSection {
                    if viewModel.phoneManager.isImporting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                        Text(viewModel.phoneManager.importStatusMessage)
                            .font(.caption)
                            .foregroundColor(.primary)
                    } else if viewModel.phoneManager.connectedDevice == nil {
                        Image(systemName: "iphone.slash")
                            .foregroundColor(.secondary)
                        Text("No iPhone connected")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if viewModel.phoneManager.isDeviceLocked {
                        Image(systemName: "lock.shield")
                            .foregroundColor(.orange)
                        Text("iPhone is Locked — Please unlock & trust")
                            .font(.caption)
                            .foregroundColor(.orange)
                    } else {
                        Image(systemName: "iphone")
                            .foregroundColor(.accentColor)
                        Text("\(viewModel.phoneManager.connectedDevice?.name ?? "iPhone") • \(viewModel.phoneManager.phoneMediaItems.count) media items")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                    }
                } else if viewModel.isNASSection {
                    Image(systemName: "server.rack")
                        .foregroundColor(.accentColor)
                    
                    HStack(spacing: 6) {
                        Text(viewModel.currentDirectoryDisplay)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("\(viewModel.fileItems.count) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else if viewModel.isSyncing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text(viewModel.syncStatusMessage)
                        .font(.caption)
                        .foregroundColor(.primary)
                } else {
                    HStack(spacing: 6) {
                        // Directory Breadcrumb
                        Text(viewModel.currentDirectoryDisplay)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        if viewModel.uncommittedCount > 0 {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.red)
                            Text("\(viewModel.uncommittedCount) uncommitted (\(viewModel.totalUncommittedSizeFormatted))")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                        } else {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("All committed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.5))
                        
                        Text("\(viewModel.filteredItems.count) items")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            // Activity Log Button
            Button {
                viewModel.showActivityLog = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "clock.arrow.circlepath")
                    Text("Activity")
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("View NAS sync and discovery activity log")
            
            // Progress bar & speed gauge
            if viewModel.isPicturesSection && viewModel.phoneManager.isImporting {
                ProgressView(value: viewModel.phoneManager.importProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
            } else if viewModel.isSyncing {
                HStack(spacing: 8) {
                    ProgressView(value: viewModel.syncProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 120)
                    
                    if viewModel.syncSpeedMBs > 0 {
                        Text(String(format: "%.1f MB/s", viewModel.syncSpeedMBs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Zoom Slider (Finder style in bottom bar)
            if isGridMode {
                HStack(spacing: 6) {
                    Image(systemName: "square.grid.3x3")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    
                    Slider(value: $gridSize, in: 80...240)
                        .frame(width: 80)
                    
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .help("Adjust thumbnail size")
            }
            
            if viewModel.isPicturesSection {
                // iPhone Import Action Buttons
                if !viewModel.selectedItemIds.isEmpty {
                    Button {
                        viewModel.importSelectedItems()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                            Text("Import (\(viewModel.selectedItemIds.count))")
                                .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.phoneManager.isImporting)
                }
                
                Button {
                    viewModel.importAllItems()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Import All")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.phoneManager.isImporting || viewModel.filteredItems.isEmpty)
            } else if !viewModel.isNASSection {
                // Sync Selected Action Button
                if !viewModel.selectedItemIds.isEmpty {
                    Button {
                        viewModel.syncSelectedItems()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text(viewModel.isSyncing ? "Syncing..." : "Sync (\(viewModel.selectedItemIds.count))")
                                .fontWeight(.medium)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(viewModel.isSyncing || !viewModel.nasOnline)
                }
                
                // Sync Action Button
                Button {
                    viewModel.syncAllUncommitted()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text(viewModel.isSyncing ? "Syncing..." : "Sync All")
                            .fontWeight(.medium)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(viewModel.uncommittedCount > 0 ? Color.accentColor : Color.secondary)
                .disabled(viewModel.isSyncing || viewModel.uncommittedCount == 0 || !viewModel.nasOnline)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }
}
