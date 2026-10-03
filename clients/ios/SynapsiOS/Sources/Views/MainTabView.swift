import SwiftUI

public struct MainTabView: View {
    @StateObject private var photosVM = PhotosViewModel()
    @State private var selectedTab: Int = 0
    
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
                .badge(photosVM.uncommittedCount > 0 ? photosVM.uncommittedCount : 0)
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
        .onAppear {
            photosVM.refresh()
        }
    }
}
