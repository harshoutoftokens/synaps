import SwiftUI
import Photos

public struct PhotosGridView: View {
    @StateObject private var viewModel = PhotosViewModel()
    
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: viewModel.columnCount)
    }
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                mainContent
                
                // Active Sync Progress Banner
                if viewModel.isSyncing {
                    syncProgressBanner
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                
                // Selection Action Bar
                if viewModel.isSelectionMode && !viewModel.isSyncing {
                    SelectionActionBar(
                        selectedCount: viewModel.selectedItemIds.count,
                        totalCount: viewModel.filteredItems.count,
                        isSyncing: viewModel.isSyncing,
                        onSelectAll: { viewModel.selectAll() },
                        onDeselectAll: { viewModel.deselectAll() },
                        onSyncSelected: { viewModel.syncSelectedItems() }
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle(viewModel.filter.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Leading: NAS Connection Status & Filter
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(viewModel.isConnectedToNAS ? Color.green : Color.red)
                            .frame(width: 8, height: 8)
                        
                        Menu {
                            Picker("Filter", selection: $viewModel.filter) {
                                ForEach(PhotosViewModel.FilterOption.allCases) { opt in
                                    Label(opt.rawValue, systemImage: opt.iconName)
                                        .tag(opt)
                                }
                            }
                        } label: {
                            Image(systemName: "line.3.horizontal.decrease.circle")
                                .font(.system(size: 16))
                        }
                    }
                }
                
                // Trailing: Column Zoom & Selection Mode
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 12) {
                        Menu {
                            Button("3 Columns (Large)") { viewModel.columnCount = 3 }
                            Button("4 Columns (Medium)") { viewModel.columnCount = 4 }
                            Button("5 Columns (Compact)") { viewModel.columnCount = 5 }
                        } label: {
                            Image(systemName: "square.grid.3x3")
                                .font(.system(size: 16))
                        }
                        
                        Button(viewModel.isSelectionMode ? "Done" : "Select") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if viewModel.isSelectionMode {
                                    viewModel.exitSelectionMode()
                                } else {
                                    viewModel.isSelectionMode = true
                                }
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                    }
                }
            }
            .refreshable {
                viewModel.refresh()
            }
            .sheet(item: $viewModel.selectedItemForDetail) { item in
                PhotoDetailView(item: item)
            }
            .onAppear {
                viewModel.refresh()
            }
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if viewModel.authorizationStatus == .notDetermined {
            permissionRequestView
        } else if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
            permissionDeniedView
        } else if viewModel.isLoading && viewModel.rawItems.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                Text("Scanning Photos Library...")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            emptyStateView
        } else {
            GeometryReader { proxy in
                let itemSize = (proxy.size.width - CGFloat(viewModel.columnCount - 1) * 2) / CGFloat(viewModel.columnCount)
                
                ScrollView {
                    LazyVStack(spacing: 16, pinnedViews: [.sectionHeaders]) {
                        // Summary status bar under nav
                        headerStatusBar
                        
                        ForEach(viewModel.groupedItems) { group in
                            Section {
                                LazyVGrid(columns: gridColumns, spacing: 2) {
                                    ForEach(group.items) { item in
                                        MediaThumbnailCell(
                                            item: item,
                                            size: itemSize,
                                            isSelectionMode: viewModel.isSelectionMode,
                                            isSelected: viewModel.selectedItemIds.contains(item.id),
                                            onSelect: {
                                                viewModel.toggleSelection(for: item)
                                            },
                                            onTap: {
                                                viewModel.selectedItemForDetail = item
                                            }
                                        )
                                    }
                                }
                            } header: {
                                DateSectionHeader(
                                    title: group.title,
                                    subtitle: group.subtitle,
                                    totalCount: group.items.count,
                                    committedCount: group.items.filter { $0.syncStatus == .committed }.count,
                                    uncommittedCount: group.items.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }.count,
                                    isSelectionMode: viewModel.isSelectionMode,
                                    onSelectSection: {
                                        for itm in group.items {
                                            viewModel.selectedItemIds.insert(itm.id)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .padding(.bottom, viewModel.isSelectionMode || viewModel.isSyncing ? 80 : 20)
                }
            }
        }
    }
    
    // Status header showing total photos, committed (green), uncommitted (red)
    private var headerStatusBar: some View {
        HStack(spacing: 16) {
            // Committed stat
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.system(size: 14))
                Text("\(viewModel.committedCount) Committed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            // Uncommitted stat
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.system(size: 14))
                Text("\(viewModel.uncommittedCount) Uncommitted")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            // Quick sync all uncommitted button if any pending
            if viewModel.uncommittedCount > 0 && !viewModel.isSyncing {
                Button {
                    viewModel.syncAllUncommitted()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                        Text("Commit All")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.blue))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(UIColor.secondarySystemBackground).opacity(0.6))
        .cornerRadius(10)
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }
    
    // Sync Progress floating banner
    private var syncProgressBanner: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.85)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Syncing to Synaps NAS...")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text(viewModel.syncItemName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text("\(viewModel.syncedCount)/\(viewModel.totalToSyncCount)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Button("Cancel") {
                    viewModel.cancelSync()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)
                .padding(.leading, 8)
            }
            
            ProgressView(value: viewModel.syncProgress)
                .accentColor(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundColor(.secondary.opacity(0.6))
            
            Text("No Photos Found")
                .font(.title3)
                .fontWeight(.bold)
            
            Text("Photos taken on this iPhone will automatically appear here with their Synaps commit status.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var permissionRequestView: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.stack")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Synaps Photos Access")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Synaps needs photo library permission to display your photos, identify uncommitted items, and sync them to your NAS.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button("Grant Access") {
                viewModel.requestAccess()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private var permissionDeniedView: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.shield")
                .font(.system(size: 60))
                .foregroundColor(.orange)
            
            Text("Photo Access Restricted")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Please enable Photo Library permissions in iOS Settings to browse and commit photos to Synaps NAS.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
