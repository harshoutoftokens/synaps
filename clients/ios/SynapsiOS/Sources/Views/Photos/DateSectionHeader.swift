import SwiftUI

public struct DateSectionHeader: View {
    public let title: String
    public let subtitle: String
    public let totalCount: Int
    public let committedCount: Int
    public let uncommittedCount: Int
    public var isSelectionMode: Bool = false
    public var onSelectSection: (() -> Void)? = nil
    
    public init(
        title: String,
        subtitle: String,
        totalCount: Int,
        committedCount: Int,
        uncommittedCount: Int,
        isSelectionMode: Bool = false,
        onSelectSection: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.totalCount = totalCount
        self.committedCount = committedCount
        self.uncommittedCount = uncommittedCount
        self.isSelectionMode = isSelectionMode
        self.onSelectSection = onSelectSection
    }
    
    public var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.primary)
                
                HStack(spacing: 8) {
                    Text(subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    
                    Text("•")
                        .foregroundColor(.secondary.opacity(0.6))
                    
                    // Committed badge preview
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.green)
                        Text("\(committedCount)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    
                    // Uncommitted badge preview
                    if uncommittedCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.red)
                            Text("\(uncommittedCount)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            
            Spacer()
            
            if isSelectionMode {
                Button {
                    onSelectSection?()
                } label: {
                    Text("Select All")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.accentColor)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            Color(UIColor.systemBackground).opacity(0.92)
        )
    }
}
