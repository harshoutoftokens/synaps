import SwiftUI

/// Floating sync progress (or last-run problem) banner. It observes SyncManager itself so the
/// frequent progress updates re-render only this view, not the photo grid behind it.
public struct SyncProgressBanner: View {
    @ObservedObject private var syncManager = SyncManager.shared
    public var title: String
    
    public init(title: String = "Syncing to Synaps NAS...") {
        self.title = title
    }
    
    public var body: some View {
        Group {
            if syncManager.isSyncing {
                progressContent
            } else if let message = syncManager.statusMessage {
                messageContent(message)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .cornerRadius(14)
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
    
    private var progressContent: some View {
        VStack(spacing: 8) {
            HStack {
                ProgressView()
                    .scaleEffect(0.85)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.primary)
                    Text(syncManager.currentItemName)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                Text("\(syncManager.syncedCount)/\(syncManager.totalToSyncCount)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.secondary)
                
                Button("Cancel") {
                    syncManager.cancelSync()
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.red)
                .padding(.leading, 8)
            }
            
            ProgressView(value: min(max(syncManager.currentProgress, 0), 1))
                .accentColor(.blue)
        }
    }
    
    private func messageContent(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.primary)
                .lineLimit(2)
            Spacer()
            Button {
                syncManager.clearStatusMessage()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityLabel("Dismiss")
        }
    }
}
