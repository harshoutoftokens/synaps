import SwiftUI

public struct UncommittedStagingView: View {
    @StateObject private var viewModel = PhotosViewModel()
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    
    private var gridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }
    
    public init() {}
    
    private var uncommittedItems: [SynapsMediaItem] {
        viewModel.rawItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }
    }
    
    private var totalUncommittedBytes: Int64 {
        uncommittedItems.reduce(0) { $0 + $1.fileSize }
    }
    
    private var formattedTotalBytes: String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useMB, .useGB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: totalUncommittedBytes)
    }
    
    public var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // Header Status Card
                    stagingHeaderCard
                    
                    if uncommittedItems.isEmpty {
                        allSyncedView
                    } else {
                        GeometryReader { proxy in
                            let itemSize = (proxy.size.width - 4) / 3
                            
                            ScrollView {
                                LazyVGrid(columns: gridColumns, spacing: 2) {
                                    ForEach(uncommittedItems) { item in
                                        MediaThumbnailCell(
                                            item: item,
                                            size: itemSize,
                                            isSelectionMode: false,
                                            onTap: {
                                                viewModel.selectedItemForDetail = item
                                            }
                                        )
                                    }
                                }
                                .padding(.bottom, 80)
                            }
                        }
                    }
                }
                
                // Commit All Floating Action Button
                if !uncommittedItems.isEmpty && !viewModel.isSyncing {
                    commitAllFloatingButton
                } else if viewModel.isSyncing {
                    syncProgressBanner
                }
            }
            .navigationTitle("Uncommitted")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $viewModel.selectedItemForDetail) { item in
                PhotoDetailView(item: item)
            }
            .refreshable {
                viewModel.refresh()
            }
            .onAppear {
                viewModel.refresh()
            }
        }
    }
    
    private var stagingHeaderCard: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.system(size: 16))
                        Text("\(uncommittedItems.count) Awaiting NAS Commit")
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
                        .fill(networkMonitor.isWifi ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                    Text(networkMonitor.isWifi ? "On Wi-Fi (Auto Active)" : "Cellular (Paused)")
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
                Text("Commit All (\(uncommittedItems.count)) to NAS")
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
    
    private var syncProgressBanner: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.85)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uploading to Synaps NAS...")
                        .font(.system(size: 13, weight: .bold))
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
        .padding(.bottom, 16)
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
