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
                if viewModel.selectedSidebarItem?.isPhone == true || displayMode == .grid {
                    PhotosGridView(viewModel: viewModel)
                } else {
                    FileListView(viewModel: viewModel)
                }
                
                // Bottom Sync Status & Action Bar
                SyncStatusBar(viewModel: viewModel)
            }
            .navigationTitle(viewModel.selectedSidebarItem?.title ?? "Synaps")
            .navigationSubtitle(viewModel.selectedSidebarItem?.path ?? "")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    // Filter Picker (All / 🔴 Uncommitted / 🟢 Committed)
                    Picker("Filter", selection: $viewModel.filterSelection) {
                        ForEach(AppViewModel.FilterOption.allCases) { opt in
                            Text(opt.rawValue).tag(opt)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 160)
                    
                    // Sort Menu
                    Menu {
                        Section("Sort By") {
                            ForEach(AppViewModel.SortField.allCases) { field in
                                Button {
                                    if viewModel.sortField == field {
                                        viewModel.sortAscending.toggle()
                                    } else {
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
                                    Text("Ascending")
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
                                    Text("Descending")
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
                    .help("Sort items by \(viewModel.sortField.rawValue) (\(viewModel.sortAscending ? "Ascending" : "Descending"))")
                    
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
                        if let sel = viewModel.selectedSidebarItem {
                            viewModel.selectSidebarItem(sel)
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan folder and check NAS")
                }
            }
            .searchable(text: $viewModel.searchQuery, prompt: "Search files or photos...")
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
