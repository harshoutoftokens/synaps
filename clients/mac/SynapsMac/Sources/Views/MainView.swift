import SwiftUI

public enum ContentDisplayMode {
    case list
    case grid
}

public struct MainView: View {
    @StateObject private var viewModel = AppViewModel()
    @State private var displayMode: ContentDisplayMode = .list
    
    public var body: some View {
        NavigationSplitView {
            SidebarView(viewModel: viewModel)
        } detail: {
            VStack(spacing: 0) {
                // Main Content View
                if viewModel.isNASSection && !viewModel.nasOnline {
                    VStack(spacing: 16) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Home Cloud is Offline")
                            .font(.title2)
                            .fontWeight(.semibold)
                        Text("Unable to reach NAS at \(viewModel.nasBaseUrl)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Button {
                            Task {
                                await viewModel.checkNASStatus()
                                if viewModel.nasOnline {
                                    viewModel.loadNASFolder(path: viewModel.currentNASRelativePath)
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                SpinningRefreshIcon(isSpinning: viewModel.isCheckingNAS)
                                Text(viewModel.isCheckingNAS ? "Reconnecting..." : "Reconnect")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isCheckingNAS)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.selectedSidebarItem?.isPhone == true || displayMode == .grid {
                    PhotosGridView(viewModel: viewModel)
                } else {
                    FileListView(viewModel: viewModel)
                }
                
                // Bottom Sync Status & Action Bar
                SyncStatusBar(viewModel: viewModel, isGridMode: displayMode == .grid || viewModel.selectedSidebarItem?.isPhone == true)
            }
            .navigationTitle(viewModel.selectedSidebarItem?.title ?? "Synaps")
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button {
                        viewModel.navigateBack()
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(viewModel.navigationHistory.isEmpty)
                    .help("Back")
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    // Filter Picker (All / 🔴 Uncommitted / 🟢 Committed)
                    if !viewModel.isNASSection {
                        Picker("Filter", selection: $viewModel.filterSelection) {
                            ForEach(AppViewModel.FilterOption.allCases) { opt in
                                Text(opt.rawValue).tag(opt)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 160)
                    }
                    
                    // Sort Menu
                    Menu {
                        Section("Sort By") {
                            ForEach(AppViewModel.SortField.allCases) { field in
                                Button {
                                    if viewModel.sortField != field {
                                        viewModel.sortField = field
                                        viewModel.sortAscending = (field == .name || field == .kind)
                                    }
                                } label: {
                                    HStack {
                                        Text(field.rawValue)
                                        if viewModel.sortField == field {
                                            Spacer()
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        
                        Section("Order") {
                            Button {
                                viewModel.sortAscending = true
                            } label: {
                                HStack {
                                    Text(ascendingLabel(for: viewModel.sortField))
                                    if viewModel.sortAscending {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                            
                            Button {
                                viewModel.sortAscending = false
                            } label: {
                                HStack {
                                    Text(descendingLabel(for: viewModel.sortField))
                                    if !viewModel.sortAscending {
                                        Spacer()
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .help("Sort items by \(viewModel.sortField.rawValue) (\(viewModel.sortAscending ? ascendingLabel(for: viewModel.sortField) : descendingLabel(for: viewModel.sortField)))")
                    
                    // Quick Look Button
                    Button {
                        viewModel.toggleQuickLook()
                    } label: {
                        Image(systemName: "eye")
                    }
                    .disabled(viewModel.selectedItemIds.isEmpty)
                    .help("Quick Look selected item(s) (Space)")
                    
                    // Display Mode Toggle (List vs Grid)
                    Picker("View", selection: $displayMode) {
                        Image(systemName: "list.bullet").tag(ContentDisplayMode.list)
                        Image(systemName: "square.grid.2x2").tag(ContentDisplayMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 70)
                    
                    // Refresh Button
                    Button {
                        viewModel.refreshCurrentFolder()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan folder and check NAS")
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search files or photos...")
            .sheet(isPresented: $viewModel.showActivityLog) {
                ActivityLogSheet(viewModel: viewModel)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
    
    private func ascendingLabel(for field: AppViewModel.SortField) -> String {
        switch field {
        case .name: return "A to Z"
        case .dateModified, .dateCreated: return "Oldest First"
        case .size: return "Smallest First"
        case .kind: return "Folders First (A to Z)"
        }
    }
    
    private func descendingLabel(for field: AppViewModel.SortField) -> String {
        switch field {
        case .name: return "Z to A"
        case .dateModified, .dateCreated: return "Newest First"
        case .size: return "Largest First"
        case .kind: return "Folders Last (Z to A)"
        }
    }
}
