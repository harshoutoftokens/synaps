import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // BGTaskScheduler requires all launch handlers to be registered before launch finishes.
        BackgroundSyncWorker.shared.registerBackgroundTasks()
        // Reconnect to uploads that kept running while the app was suspended or terminated.
        UploadSessionManager.shared.activate()
        #if DEBUG
        applyDebugLaunchArguments()
        #endif
        return true
    }
    
    /// The system relaunched us because background uploads finished or need attention.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        UploadSessionManager.shared.handleEventsForBackgroundURLSession(identifier: identifier, completionHandler: completionHandler)
    }
    
    #if DEBUG
    /// Simulator test hooks (compiled out of release builds):
    ///   -SynapsNASURLOverride http://127.0.0.1:8765   talk to a local mock server instead of the saved URL
    ///   -SynapsSeedAPIToken <token>                   store an API token in the Keychain at launch
    ///   -SynapsSyncAllOnLaunch YES                    commit every uncommitted item once the library loads
    ///   -SynapsInitialTab 2 / -SynapsVaultPath Vault  open the NAS Vault tab in a given folder
    private func applyDebugLaunchArguments() {
        let defaults = UserDefaults.standard
        if let token = defaults.string(forKey: "SynapsSeedAPIToken") {
            let saved = APITokenStore.setToken(token)
            print("[debug] seeded API token in Keychain: \(saved)")
        }
        if defaults.bool(forKey: "SynapsSyncAllOnLaunch") {
            Task { @MainActor in
                await PhotoLibraryService.shared.fetchAllMedia()
                let pending = PhotoLibraryService.shared.mediaItems.filter { $0.syncStatus != .committed }
                print("[debug] syncing \(pending.count) items on launch")
                SyncManager.shared.syncItems(pending, trigger: .manual)
            }
        }
    }
    #endif
}
