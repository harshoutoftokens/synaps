import SwiftUI

public struct UncommittedStagingView: View {
    @EnvironmentObject private var viewModel: PhotosViewModel
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @State private var detailItem: SynapsMediaItem? = nil
    
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }
    
    public init() {}
    
    /// Cached by the view model (uncommitted, failed and in-flight items).
    private var pendingItems: [SynapsMediaItem] {
        viewModel.pendingItems
    }
    
    private var formattedTotalBytes: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: viewModel.pendingBytes)
    }
    
    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Header Status Card
                    stagingHeaderCard
                    
                    if viewModel.rawItems.isEmpty && (viewModel.isLoading || !(viewModel.authorizationStatus == .authorized || viewModel.authorizationStatus == .limited)) {
                        // Library not loaded / not authorized yet: don't claim everything is committed.
                        VStack(spacing: 12) {
                            if viewModel.isLoading {
                                ProgressView()
                            }
                            Text(viewModel.isLoading ? "Loading Photos Library..." : "Grant photo access in the Photos tab to see pending items.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if pendingItems.isEmpty {
                        allSyncedView
                    } else {
                        GeometryReader { proxy in
                            let itemSize = (proxy.size.width - 4) / 3
                            
                            ScrollView {
                                LazyVGrid(columns: gridColumns, spacing: 2) {
                                    ForEach(pendingItems) { item in
                                        MediaThumbnailCell(
                                            item: item,
                                            size: itemSize,
                                            isSelectionMode: false,
                                            onTap: {
                                                detailItem = item
                                            }
                                        )
                                    }
                                }
                                .padding(.bottom, 80)
                            }
                            .refreshable {
                                await viewModel.refreshAsync()
                            }
                        }
                    }
                }
                
                // Commit All Floating Action Button
                if viewModel.isSyncing || viewModel.syncStatusMessage != nil {
                    SyncProgressBanner(title: "Uploading to Synaps NAS...")
                } else if viewModel.uncommittedCount > 0 {
                    commitAllFloatingButton
                }
            }
            .navigationTitle("Uncommitted")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $detailItem) { item in
                PhotoDetailView(item: item)
            }
        }
    }
    
    private var networkPillText: String {
        if !networkMonitor.isConnected {
            return "Offline"
        }
        if networkMonitor.isUnmeteredLAN {
            return SynapsConfig.load().autoSyncOnWifi ? "On Wi-Fi (Auto Active)" : "On Wi-Fi (Auto Off)"
        }
        return networkMonitor.isCellular ? "Cellular (Paused)" : "Metered network (Paused)"
    }
    
    private var stagingHeaderCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 16))
                        Text("\(viewModel.uncommittedCount) Awaiting NAS Commit")
                            .font(.system(size: 16, weight: .bold))
                    }
                    
                    Text("\(formattedTotalBytes) to transfer")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Wi-Fi Auto-sync status pill
                HStack(spacing: 6) {
                    Circle()
                        .fill(networkMonitor.isUnmeteredLAN ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(networkPillText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color(UIColor.tertiarySystemBackground))
                .cornerRadius(20)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(UIColor.secondarySystemBackground))
    }
    
    private var commitAllFloatingButton: some View {
        Button {
            viewModel.syncAllUncommitted()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 20, weight: .bold))
                Text("Commit All (\(viewModel.uncommittedCount)) to NAS")
                    .font(.system(size: 16, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                Capsule()
                    .fill(Color.blue)
                    .shadow(color: Color.blue.opacity(0.4), radius: 8, x: 0, y: 4)
            )
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
    }
    
    private var allSyncedView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            
            Text("All Photos Committed!")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Every photo and video on your iPhone has been safely stored in your Synaps NAS vault.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
