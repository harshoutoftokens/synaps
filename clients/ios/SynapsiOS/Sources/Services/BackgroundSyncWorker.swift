import Foundation
import BackgroundTasks
import UIKit

/// Calls setTaskCompleted exactly once, whichever of {work finished, expiration} comes first.
private final class BGTaskCompleter: @unchecked Sendable {
    private let lock = NSLock()
    private let task: BGTask
    private var done = false
    
    init(_ task: BGTask) {
        self.task = task
    }
    
    func complete(success: Bool) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}

public final class BackgroundSyncWorker: @unchecked Sendable {
    public static let shared = BackgroundSyncWorker()
    
    // Must match BGTaskSchedulerPermittedIdentifiers in Info.plist.
    public static let refreshTaskId = "com.synaps.ios.backgroundsync"
    public static let processingTaskId = "com.synaps.ios.photoprocessing"
    
    private let lock = NSLock()
    private var registered = false
    
    private init() {}
    
    /// Must run before the app finishes launching (AppDelegate.didFinishLaunching).
    /// Registering the same identifier twice raises, so this is idempotent.
    public func registerBackgroundTasks() {
        lock.lock()
        guard !registered else {
            lock.unlock()
            return
        }
        registered = true
        lock.unlock()
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            self.handle(task, limit: 20, timeout: 25)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskId, using: nil) { task in
            self.handle(task, limit: nil, timeout: nil)
        }
        
        // Live Wi-Fi join events while the app is running.
        Task { @MainActor in
            NetworkMonitor.shared.onWifiConnected = {
                BackgroundSyncWorker.shared.triggerWifiAutoSync()
            }
        }
    }
    
    /// Submits (or, when the background worker is disabled, cancels) the BG requests.
    public func scheduleNextBackgroundSync() {
        let cfg = SynapsConfig.load()
        guard cfg.backgroundTaskEnabled && cfg.autoSyncOnWifi else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshTaskId)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingTaskId)
            return
        }
        
        // App refresh: short (~30 s) runs; picks up a few new photos and hands them to the
        // background upload session, which keeps going after the task ends.
        let refreshRequest = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
        } catch {
            print("Could not schedule BGAppRefresh: \(error)")
        }
        
        // Processing: long runs, typically overnight on power, for the bulk of the backlog.
        let processingRequest = BGProcessingTaskRequest(identifier: Self.processingTaskId)
        processingRequest.requiresNetworkConnectivity = true
        processingRequest.requiresExternalPower = cfg.requireCharging
        processingRequest.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(processingRequest)
        } catch {
            print("Could not schedule BGProcessingTask: \(error)")
        }
    }
    
    /// Triggered whenever the device joins unmetered Wi-Fi/Ethernet while the app is running.
    public func triggerWifiAutoSync() {
        Task { @MainActor in
            await SyncManager.shared.requestAutomaticSync()
        }
    }
    
    private func handle(_ task: BGTask, limit: Int?, timeout: TimeInterval?) {
        scheduleNextBackgroundSync()
        let completer = BGTaskCompleter(task)
        
        // Set before starting work so an immediate expiry is still handled. Uploads already
        // handed to the background URLSession keep running after we complete.
        task.expirationHandler = {
            Task { @MainActor in
                SyncManager.shared.stopAfterCurrentStep()
            }
            completer.complete(success: false)
        }
        
        Task { @MainActor in
            await PhotoLibraryService.shared.fetchAllMedia()
            let ok = await SyncManager.shared.runBackgroundSync(limit: limit, timeout: timeout)
            if timeout != nil {
                // App refresh budget is nearly spent: stop exporting, keep queued uploads.
                SyncManager.shared.stopAfterCurrentStep()
            }
            completer.complete(success: ok)
        }
    }
}
