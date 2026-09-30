import SwiftUI

public struct ActivityLogSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var filterQuery: String = ""
    
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()
    
    private var filteredActivities: [SyncActivityItem] {
        if filterQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return viewModel.recentActivities
        }
        let q = filterQuery.lowercased()
        return viewModel.recentActivities.filter {
            ($0.filename?.lowercased().contains(q) ?? false) ||
            ($0.filePath?.lowercased().contains(q) ?? false) ||
            $0.details.lowercased().contains(q) ||
            $0.eventType.title.lowercased().contains(q)
        }
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundColor(.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("NAS Activity & Sync Log")
                            .font(.headline)
                        Text("\(viewModel.recentActivities.count) logged events")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Button {
                    viewModel.loadRecentActivities()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh Log")
                
                Button("Clear Log") {
                    viewModel.clearRecentActivities()
                }
                .disabled(viewModel.recentActivities.isEmpty)
                
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
            
            Divider()
            
            // Search / Filter
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter activity log...", text: $filterQuery)
                    .textFieldStyle(.plain)
                if !filterQuery.isEmpty {
                    Button {
                        filterQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)
            
            Divider()
            
            // Activity List
            if filteredActivities.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(filterQuery.isEmpty ? "No Activity Logged Yet" : "No Matching Activity")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Reconciliations, discoveries, and synchronization events will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredActivities) { item in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: item.eventType.iconName)
                            .font(.title3)
                            .foregroundColor(item.eventType.color)
                            .frame(width: 24, height: 24)
                        
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(item.eventType.title)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(dateFormatter.string(from: item.timestamp))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            
                            if let fn = item.filename {
                                Text(fn)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                            }
                            
                            Text(item.details)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 550, idealWidth: 600, minHeight: 400, idealHeight: 480)
        .onAppear {
            viewModel.loadRecentActivities()
        }
    }
}
