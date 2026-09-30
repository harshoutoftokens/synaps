import SwiftUI
import AppKit

public struct SynapsMacApp: App {
    public init() {}
    
    public var body: some Scene {
        WindowGroup {
            MainView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
        }
    }
}
