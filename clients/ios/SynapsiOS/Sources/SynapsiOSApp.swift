import SwiftUI
import BackgroundTasks

@main
public struct SynapsiOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    public init() {
        // Register Background Tasks (BGAppRefresh & BGProcessing)
        BackgroundSyncWorker.shared.registerBackgroundTasks()
    }
    
    public var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                BackgroundSyncWorker.shared.scheduleNextBackgroundSync()
            case .active:
                Task {
                    await SyncManager.shared.checkNASStatus()
                }
            default:
                break
            }
        }
    }
}
