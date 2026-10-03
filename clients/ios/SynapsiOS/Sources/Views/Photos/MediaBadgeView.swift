import SwiftUI

public struct MediaBadgeView: View {
    public let status: SyncStatus
    public var size: CGFloat = 20
    
    public init(status: SyncStatus, size: CGFloat = 20) {
        self.status = status
        self.size = size
    }
    
    public var body: some View {
        ZStack {
            // Contrast circle background for maximum visibility on bright/dark photos
            Circle()
                .fill(Color.black.opacity(0.65))
                .frame(width: size + 3, height: size + 3)
                .shadow(color: Color.black.opacity(0.35), radius: 2, x: 0, y: 1)
            
            switch status {
            case .committed:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(Color(red: 0.18, green: 0.82, blue: 0.35)) // Vivid Apple green
                    .frame(width: size, height: size)
            case .uncommitted:
                Image(systemName: "xmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(Color(red: 1.0, green: 0.28, blue: 0.28)) // Vivid red cross
                    .frame(width: size, height: size)
            case .syncing:
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: Color.white))
                    .scaleEffect(size / 24.0)
                    .frame(width: size, height: size)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(Color.orange)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityLabel(status.labelText)
    }
}
