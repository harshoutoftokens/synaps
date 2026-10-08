import SwiftUI
import Photos

public struct PhotosGridView: View {
    @StateObject private var viewModel = PhotosViewModel()
    
    private var gridSpacing: CGFloat { 1.5 }
    
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: gridSpacing), count: viewModel.columnCount)
    }
    
    public init() {}
    
    public var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let safeAreaTop = proxy.safeAreaInsets.top
                let headerContentHeight: CGFloat = 68
                let totalHeaderHeight = safeAreaTop + headerContentHeight + 16
                let itemSize = (proxy.size.width - gridSpacing * CGFloat(viewModel.columnCount - 1)) / CGFloat(viewModel.columnCount)
                
                ZStack(alignment: .top) {
                    Color.black.ignoresSafeArea()
                    
                    // Main Scrollable Continuous Timeline Grid
                    mainScrollContent(topOffset: totalHeaderHeight, itemSize: itemSize)
                    
                    // Floating Apple Photos Top Header with Gradient Blur
                    floatingTopHeader(safeAreaTop: safeAreaTop)
                    
                    // Bottom Floating Overlays: Sync Progress or Selection Action Bar
                    VStack {
                        Spacer()
                        
                        if viewModel.isSyncing {
                            syncProgressBanner
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else if viewModel.isSelectionMode {
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
                }
            }
            .navigationBarHidden(true)
            .sheet(item: $viewModel.selectedItemForDetail) { item in
                PhotoDetailView(item: item)
            }
            .onAppear {
                viewModel.refresh()
            }
        }
    }
    
    // MARK: - Continuous Timeline Grid
    @ViewBuilder
    private func mainScrollContent(topOffset: CGFloat, itemSize: CGFloat) -> some View {
        if viewModel.authorizationStatus == .notDetermined {
            permissionRequestView
        } else if viewModel.authorizationStatus == .denied || viewModel.authorizationStatus == .restricted {
            permissionDeniedView
        } else if viewModel.isLoading && viewModel.rawItems.isEmpty {
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text("Loading Photos Library...")
                    .foregroundColor(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if viewModel.filteredItems.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    // Top spacer allowing first row to appear directly below header
                    Color.clear
                        .frame(height: topOffset)
                    
                    // One Continuous Timeline Grid — No day or section breaks!
                    LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
                        ForEach(Array(viewModel.filteredItems.enumerated()), id: \.element.id) { index, item in
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
                            .onAppear {
                                viewModel.itemDidAppear(at: index, date: item.createdAt)
                            }
                            .onDisappear {
                                viewModel.itemDidDisappear(at: index)
                            }
                        }
                    }
                    .padding(.bottom, viewModel.isSelectionMode || viewModel.isSyncing ? 80 : 30)
                }
            }
            .ignoresSafeArea(edges: .top)
            .refreshable {
                viewModel.refresh()
            }
        }
    }
    
    // MARK: - Floating Top Header with Blur & Fade Mask
    private func floatingTopHeader(safeAreaTop: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                // Title & Dynamic Date Subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text("Library")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)
                    
                    Text(viewModel.visibleDateRangeText.isEmpty ? "All Photos" : viewModel.visibleDateRangeText)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                }
                
                Spacer()
                
                // Controls: Filter Button & Select Pill
                HStack(spacing: 10) {
                    // Filter Menu Button (Translucent dark circle with 3 horizontal lines)
                    Menu {
                        Picker("Filter", selection: $viewModel.filter) {
                            ForEach(PhotosViewModel.FilterOption.allCases) { opt in
                                Label(opt.rawValue, systemImage: opt.iconName)
                                    .tag(opt)
                            }
                        }
                        
                        Divider()
                        
                        Section("Grid Size") {
                            Button {
                                viewModel.columnCount = 3
                            } label: {
                                Label("3 Columns (Large)", systemImage: viewModel.columnCount == 3 ? "checkmark" : "")
                            }
                            
                            Button {
                                viewModel.columnCount = 5
                            } label: {
                                Label("5 Columns (Compact)", systemImage: viewModel.columnCount == 5 ? "checkmark" : "")
                            }
                        }
                        
                        Divider()
                        
                        Label(
                            viewModel.isConnectedToNAS ? "Synaps NAS Online" : "Synaps NAS Offline",
                            systemImage: viewModel.isConnectedToNAS ? "externaldrive.badge.checkmark" : "externaldrive.badge.xmark"
                        )
                        
                        Button {
                            viewModel.syncAllUncommitted()
                        } label: {
                            Label("Commit All Uncommitted (\(viewModel.uncommittedCount))", systemImage: "arrow.up.circle")
                        }
                        .disabled(viewModel.uncommittedCount == 0 || viewModel.isSyncing)
                    } label: {
                        Image(systemName: "line.3.horizontal")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 38, height: 38)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.55))
                                    .background(.ultraThinMaterial, in: Circle())
                            )
                    }
                    
                    // Select Pill Button (Translucent dark capsule with "Select" text)
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if viewModel.isSelectionMode {
                                viewModel.exitSelectionMode()
                            } else {
                                viewModel.isSelectionMode = true
                            }
                        }
                    } label: {
                        Text(viewModel.isSelectionMode ? "Done" : "Select")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .frame(height: 38)
                            .background(
                                Capsule()
                                    .fill(viewModel.isSelectionMode ? Color.blue : Color.black.opacity(0.55))
                                    .background(.ultraThinMaterial, in: Capsule())
                            )
                    }
                }
                .padding(.top, 4)
            }
            .padding(.horizontal, 16)
            .padding(.top, safeAreaTop > 0 ? safeAreaTop + 4 : 12)
            .padding(.bottom, 16)
        }
        .background(
            ZStack {
                // Subtle blur fading into clear at bottom
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.70),
                                .init(color: .black.opacity(0.35), location: 0.88),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                
                // Subtle dark gradient overlay for text readability
                LinearGradient(
                    stops: [
                        .init(color: Color.black.opacity(0.70), location: 0.0),
                        .init(color: Color.black.opacity(0.40), location: 0.72),
                        .init(color: .clear, location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea(edges: .top)
        )
    }
    
    // MARK: - Sync Progress Banner
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
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    
    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 54))
                .foregroundColor(.white.opacity(0.4))
            
            Text("No Photos Found")
                .font(.title3)
                .fontWeight(.bold)
                .foregroundColor(.white)
            
            Text("Photos taken on this iPhone will automatically appear here with their Synaps commit status.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
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
                .foregroundColor(.white)
            
            Text("Synaps needs photo library permission to display your photos, indicate vault commit status, and sync them to your NAS.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
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
                .foregroundColor(.white)
            
            Text("Please enable Photo Library permissions in iOS Settings to browse and commit photos to Synaps NAS.")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
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
