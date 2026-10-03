import SwiftUI
import Photos
import UIKit

public struct PhotoDetailView: View {
    public let item: SynapsMediaItem
    @Environment(\.dismiss) private var dismiss
    @StateObject private var syncManager = SyncManager.shared
    
    @State private var fullImage: UIImage? = nil
    @State private var showInfoSheet = false
    @State private var currentItem: SynapsMediaItem
    @State private var scale: CGFloat = 1.0
    
    public init(item: SynapsMediaItem) {
        self.item = item
        self._currentItem = State(initialValue: item)
    }
    
    public var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                // Full Screen Image
                Group {
                    if let img = fullImage {
                        Image(uiImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in
                                        scale = max(1.0, min(val, 4.0))
                                    }
                                    .onEnded { _ in
                                        withAnimation(.spring()) {
                                            if scale < 1.0 { scale = 1.0 }
                                        }
                                    }
                            )
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text("Loading media...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // Overlay Top & Bottom Controls
                VStack {
                    // Top Bar
                    HStack {
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(.white.opacity(0.8))
                        }
                        
                        Spacer()
                        
                        // Status Pill Badge (Green Committed or Red Uncommitted)
                        HStack(spacing: 6) {
                            MediaBadgeView(status: currentItem.syncStatus, size: 16)
                            Text(currentItem.syncStatus.labelText)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.7))
                        )
                        
                        Spacer()
                        
                        Button {
                            showInfoSheet = true
                        } label: {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 26))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    
                    Spacer()
                    
                    // Bottom Controls Bar
                    HStack(spacing: 24) {
                        // Share
                        if let img = fullImage {
                            ShareLink(item: Image(uiImage: img), preview: SharePreview(currentItem.filename, image: Image(uiImage: img))) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 20))
                                    .foregroundColor(.white)
                            }
                        }
                        
                        Spacer()
                        
                        // Sync / Commit to NAS Button
                        Button {
                            syncCurrentItem()
                        } label: {
                            HStack(spacing: 8) {
                                if currentItem.syncStatus == .syncing {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                        .scaleEffect(0.8)
                                    Text("Syncing to NAS...")
                                } else if currentItem.syncStatus == .committed {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Committed to NAS")
                                } else {
                                    Image(systemName: "arrow.up.circle.fill")
                                    Text("Commit to NAS")
                                }
                            }
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(
                                Capsule()
                                    .fill(currentItem.syncStatus == .committed ? Color.green.opacity(0.3) : Color.blue)
                            )
                        }
                        .disabled(currentItem.syncStatus == .syncing)
                        
                        Spacer()
                        
                        // Favorite toggle icon
                        Image(systemName: currentItem.isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 22))
                            .foregroundColor(currentItem.isFavorite ? .pink : .white)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 14)
                    .background(
                        Color.black.opacity(0.75)
                    )
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $showInfoSheet) {
                MediaInfoSheet(item: currentItem)
            }
            .onAppear {
                loadFullMedia()
            }
        }
    }
    
    private func loadFullMedia() {
        PhotoLibraryService.shared.requestFullImage(for: currentItem.localIdentifier) { img in
            self.fullImage = img
        }
    }
    
    private func syncCurrentItem() {
        syncManager.syncItems([currentItem])
        // Update local item status once complete
        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let rec = LocalCacheStore.shared.getRecord(id: currentItem.id) {
                await MainActor.run {
                    self.currentItem.syncStatus = SyncStatus(rawValue: rec.syncStatus) ?? .uncommitted
                    self.currentItem.sha256 = rec.sha256
                }
            }
        }
    }
}

public struct MediaInfoSheet: View {
    public let item: SynapsMediaItem
    @Environment(\.dismiss) private var dismiss
    @State private var copiedSha = false
    
    public var body: some View {
        NavigationStack {
            List {
                Section("Media Details") {
                    LabeledContent("Filename", value: item.filename)
                    if !item.formattedDimensions.isEmpty {
                        LabeledContent("Dimensions", value: item.formattedDimensions)
                    }
                    LabeledContent("File Size", value: item.formattedSize)
                    LabeledContent("Type", value: item.isVideo ? "Video" : (item.isLivePhoto ? "Live Photo" : "Photo"))
                    if let dur = item.formattedDuration {
                        LabeledContent("Duration", value: dur)
                    }
                }
                
                Section("Dates") {
                    LabeledContent("Created", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("Modified", value: item.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                
                Section("Synaps NAS Vault Status") {
                    HStack {
                        Text("Status")
                        Spacer()
                        MediaBadgeView(status: item.syncStatus, size: 16)
                        Text(item.syncStatus.labelText)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(item.syncStatus.color)
                    }
                    
                    if let sha = item.sha256 {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("SHA-256 Checksum")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(sha)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.primary)
                            
                            Button {
                                UIPasteboard.general.string = sha
                                copiedSha = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedSha = false
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: copiedSha ? "checkmark" : "doc.on.doc")
                                    Text(copiedSha ? "Copied" : "Copy Hash")
                                }
                                .font(.caption2)
                            }
                            .buttonStyle(.bordered)
                            .padding(.top, 2)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Text("Hash computed automatically upon commit.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    LabeledContent("Path", value: item.originalPath)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
