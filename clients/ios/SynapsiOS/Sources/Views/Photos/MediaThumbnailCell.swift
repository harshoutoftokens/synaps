import SwiftUI
import Photos
import UIKit

public struct MediaThumbnailCell: View {
    public let item: SynapsMediaItem
    public let size: CGFloat
    public var isSelectionMode: Bool = false
    public var isSelected: Bool = false
    public var onSelect: (() -> Void)? = nil
    public var onTap: (() -> Void)? = nil
    
    @State private var thumbnail: UIImage? = nil
    
    public init(
        item: SynapsMediaItem,
        size: CGFloat,
        isSelectionMode: Bool = false,
        isSelected: Bool = false,
        onSelect: (() -> Void)? = nil,
        onTap: (() -> Void)? = nil
    ) {
        self.item = item
        self.size = size
        self.isSelectionMode = isSelectionMode
        self.isSelected = isSelected
        self.onSelect = onSelect
        self.onTap = onTap
    }
    
    public var body: some View {
        ZStack {
            // Base Media Image
            Group {
                if let img = thumbnail {
                    Image(uiImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: size, height: size)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(UIColor.secondarySystemBackground))
                        .frame(width: size, height: size)
                        .overlay(
                            Image(systemName: item.isVideo ? "video.fill" : "photo")
                                .foregroundColor(.secondary.opacity(0.35))
                                .font(.system(size: size * 0.25))
                        )
                }
            }
            
            // Top-Left Badges: Favorite Heart or Live Photo
            VStack {
                HStack(spacing: 4) {
                    if item.isLivePhoto {
                        Image(systemName: "livephoto")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    } else if item.isFavorite {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.pink)
                            .padding(3)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    Spacer()
                }
                .padding(4)
                Spacer()
            }
            
            // Bottom Area:
            // - Bottom-Left: Synaps Commit Status (🟢 Green Tick / 🔴 Red Cross)
            // - Bottom-Right: Video Duration (e.g. 0:09, matching Apple Photos screenshot)
            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    // Synaps Vault Status Badge (Bottom-Left)
                    MediaBadgeView(status: item.syncStatus, size: max(14, min(18, size * 0.16)))
                    
                    Spacer()
                    
                    // Video Duration Badge (Bottom-Right, matching Apple Photos)
                    if item.isVideo, let dur = item.formattedDuration {
                        Text(dur)
                            .font(.system(size: max(10, min(12, size * 0.12)), weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: Color.black.opacity(0.9), radius: 2, x: 0, y: 1)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1.5)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.black.opacity(0.45))
                            )
                    }
                }
                .padding(3.5)
            }
            
            // Selection Overlay & Checkmark (Top-Right)
            if isSelectionMode {
                Color.black.opacity(isSelected ? 0.28 : 0.05)
                
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.blue : Color.black.opacity(0.4))
                                .frame(width: max(20, min(24, size * 0.22)), height: max(20, min(24, size * 0.22)))
                            
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: max(10, size * 0.11), weight: .bold))
                                    .foregroundColor(.white)
                            } else {
                                Circle()
                                    .stroke(Color.white.opacity(0.85), lineWidth: 1.5)
                                    .frame(width: max(18, min(22, size * 0.20)), height: max(18, min(22, size * 0.20)))
                            }
                        }
                        .padding(4)
                    }
                    Spacer()
                }
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onSelect?()
            } else {
                onTap?()
            }
        }
        .onAppear {
            loadThumbnail()
        }
    }
    
    private func loadThumbnail() {
        guard thumbnail == nil else { return }
        let scale = UIScreen.main.scale
        let pixelSize = CGSize(width: size * scale, height: size * scale)
        PhotoLibraryService.shared.requestThumbnail(for: item.localIdentifier, targetSize: pixelSize) { img in
            self.thumbnail = img
        }
    }
}
