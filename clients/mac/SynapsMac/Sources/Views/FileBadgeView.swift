import SwiftUI

public struct FileBadgeView: View {
    public let status: SyncStatus
    public var size: CGFloat = 18
    
    public init(status: SyncStatus, size: CGFloat = 18) {
        self.status = status
        self.size = size
    }
    
    public var body: some View {
        ZStack {
            Circle()
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: size + 3, height: size + 3)
                .shadow(color: Color.black.opacity(0.2), radius: 2, x: 0, y: 1)
            
            if status == .syncing {
                ProgressView()
                    .scaleEffect(size / 24.0)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: status.iconSystemName)
                    .resizable()
                    .scaledToFit()
                    .foregroundColor(status.color)
                    .frame(width: size, height: size)
            }
        }
        .help(status.labelText)
    }
}
