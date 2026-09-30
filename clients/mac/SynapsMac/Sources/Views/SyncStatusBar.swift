import SwiftUI

public struct SyncStatusBar: View {
    @ObservedObject var viewModel: AppViewModel
    
    public var body: some View {
        HStack(spacing: 16) {
            // Status and Uncommitted Summary
            HStack(spacing: 8) {
                if viewModel.isSyncing {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                    Text(viewModel.syncStatusMessage)
                        .font(.caption)
                        .foregroundColor(.primary)
                } else if viewModel.uncommittedCount > 0 {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.red)
                    Text("\(viewModel.uncommittedCount) uncommitted (\(viewModel.totalUncommittedSizeFormatted))")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("All files committed to NAS Vault")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Sync progress bar & speed gauge
            if viewModel.isSyncing {
                HStack(spacing: 8) {
                    ProgressView(value: viewModel.syncProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                    
                    if viewModel.syncSpeedMBs > 0 {
                        Text(String(format: "%.1f MB/s", viewModel.syncSpeedMBs))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // Sync Action Button
            Button {
                viewModel.syncAllUncommitted()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(viewModel.isSyncing ? "Syncing..." : "Sync to NAS")
                        .fontWeight(.semibold)
                }
                .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .tint(viewModel.uncommittedCount > 0 ? Color.accentColor : Color.secondary)
            .disabled(viewModel.isSyncing || viewModel.uncommittedCount == 0 || !viewModel.nasOnline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }
}
