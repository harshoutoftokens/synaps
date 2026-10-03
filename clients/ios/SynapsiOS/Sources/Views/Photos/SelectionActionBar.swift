import SwiftUI

public struct SelectionActionBar: View {
    public let selectedCount: Int
    public let totalCount: Int
    public let isSyncing: Bool
    public var onSelectAll: () -> Void
    public var onDeselectAll: () -> Void
    public var onSyncSelected: () -> Void
    
    public init(
        selectedCount: Int,
        totalCount: Int,
        isSyncing: Bool,
        onSelectAll: @escaping () -> Void,
        onDeselectAll: @escaping () -> Void,
        onSyncSelected: @escaping () -> Void
    ) {
        self.selectedCount = selectedCount
        self.totalCount = totalCount
        self.isSyncing = isSyncing
        self.onSelectAll = onSelectAll
        self.onDeselectAll = onDeselectAll
        self.onSyncSelected = onSyncSelected
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            
            HStack(spacing: 16) {
                // Select/Deselect All toggle button
                Button {
                    if selectedCount == totalCount {
                        onDeselectAll()
                    } else {
                        onSelectAll()
                    }
                } label: {
                    Text(selectedCount == totalCount ? "Deselect All" : "Select All")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                // Status counter
                Text("\(selectedCount) Selected")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.secondary)
                
                Spacer()
                
                // Sync Selected Action Button
                Button {
                    onSyncSelected()
                } label: {
                    HStack(spacing: 6) {
                        if isSyncing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        
                        Text(isSyncing ? "Syncing..." : "Sync to NAS")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(selectedCount > 0 ? Color.blue : Color.gray.opacity(0.5))
                    )
                }
                .disabled(selectedCount == 0 || isSyncing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                .ultraThinMaterial
            )
        }
    }
}
