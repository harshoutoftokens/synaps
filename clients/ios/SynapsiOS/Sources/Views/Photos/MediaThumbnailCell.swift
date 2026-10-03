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
                                .foregroundColor(.secondary.opacity(0.5))
                                .font(.system(size: size * 0.28))
                        )
                }
            }
            
            // Video Duration & Play Icon Overlay (Bottom-Left)
            if item.isVideo {
                VStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9))
                        if let dur = item.formattedDuration {
                            Text(dur)
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                        }
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2.5)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.6))
                    )
                    .padding(5)
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                }
            } else if item.isLivePhoto {
                // Live photo icon (Top-Left)
                VStack {
                    HStack {
                        Image(systemName: "livephoto")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }
            
            // Favorite Badge (Top-Left, below live photo if any)
            if item.isFavorite && !item.isLivePhoto {
                VStack {
                    HStack {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.pink)
                            .padding(4)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                            .padding(4)
                        Spacer()
                    }
                    Spacer()
                }
            }
            
            // Sync Status Indicator Badge (Bottom-Right)
            // Green tick for committed, Red cross for uncommitted, Blue for syncing
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    MediaBadgeView(status: item.syncStatus, size: max(16, min(22, size * 0.18)))
                        .padding(4)
                }
            }
            
            // Selection Overlay & Checkmark (Top-Right)
            if isSelectionMode {
                Color.black.opacity(isSelected ? 0.25 : 0.05)
                
                VStack {
                    HStack {
                        Spacer()
                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.blue : Color.black.opacity(0.4))
                                .frame(width: 24, height: 24)
                            
                            if isSelected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            } else {
                                Circle()
                                    .stroke(Color.white.opacity(0.8), lineWidth: 1.5)
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .padding(5)
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
