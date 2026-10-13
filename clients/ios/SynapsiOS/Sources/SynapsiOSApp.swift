import SwiftUI
import BackgroundTasks

@main
public struct SynapsiOSApp: App {
    // Background-task registration and background-URLSession relaunch handling live in the
    // app delegate (didFinishLaunching runs before launch completes, as BGTaskScheduler requires).
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    
    public init() {}
    
    public var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                BackgroundSyncWorker.shared.scheduleNextBackgroundSync()
            case .active:
                SyncManager.shared.appDidBecomeActive()
            default:
                break
            }
        }
    }
}
