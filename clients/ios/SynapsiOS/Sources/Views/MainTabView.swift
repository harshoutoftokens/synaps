import SwiftUI

public struct MainTabView: View {
    /// Shared by every tab: the library is enumerated and filtered once, not once per tab.
    @StateObject private var photosVM = PhotosViewModel()
    @State private var selectedTab: Int = MainTabView.initialTab
    
    private static var initialTab: Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: "SynapsInitialTab") // simulator test hook
        #else
        return 0
        #endif
    }
    
    public init() {}
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            PhotosGridView()
                .tabItem {
                    Label("Photos", systemImage: "photo.on.rectangle.angled")
                }
                .tag(0)
            
            UncommittedStagingView()
                .tabItem {
                    Label("Uncommitted", systemImage: "arrow.up.circle.fill")
                }
                .badge(photosVM.uncommittedCount)
                .tag(1)
            
            NASVaultView()
                .tabItem {
                    Label("NAS Vault", systemImage: "externaldrive.fill")
                }
                .tag(2)
            
            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
                .tag(3)
        }
        .environmentObject(photosVM)
        .task {
            await photosVM.initialLoad()
        }
    }
}
