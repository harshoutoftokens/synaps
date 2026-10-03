import SwiftUI

public struct ActivityLogSheet: View {
    @ObservedObject var settingsViewModel: SettingsViewModel
    @Environment(\.dismiss) private var dismiss
    
    public init(settingsViewModel: SettingsViewModel) {
        self.settingsViewModel = settingsViewModel
    }
    
    public var body: some View {
        NavigationStack {
            List {
                if settingsViewModel.recentActivities.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Sync Activity Recorded Yet")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("When photos are committed, uploaded, or deduplicated, they appear here.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                } else {
                    ForEach(settingsViewModel.recentActivities) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.eventType.iconName)
                                .font(.system(size: 18))
                                .foregroundColor(color(for: item.eventType))
                                .frame(width: 24, height: 24)
                            
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(item.filename.isEmpty ? item.eventType.rawValue : item.filename)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Text(item.details)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(2)
                                
                                Text(item.eventType.rawValue)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(color(for: item.eventType))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(color(for: item.eventType).opacity(0.12))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Activity Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .destructiveAction) {
                    if !settingsViewModel.recentActivities.isEmpty {
                        Button("Clear") {
                            settingsViewModel.clearActivities()
                        }
                    }
                }
            }
            .onAppear {
                settingsViewModel.loadActivities()
            }
        }
    }
    
    private func color(for eventType: SyncActivityItem.EventType) -> Color {
        switch eventType {
        case .committed, .dedupLinked:
            return .green
        case .uploaded:
            return .blue
        case .failed:
            return .red
        case .scanned:
            return .secondary
        }
    }
}
