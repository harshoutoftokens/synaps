import Foundation
import BackgroundTasks
import UIKit

public final class BackgroundSyncWorker: @unchecked Sendable {
    public static let shared = BackgroundSyncWorker()
    
    public static let refreshTaskId = "com.synaps.ios.backgroundsync"
    public static let processingTaskId = "com.synaps.ios.photoprocessing"
    
    private init() {}
    
    /// Call from Application launch to register background task handlers
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleAppRefresh(task: appRefreshTask)
        }
        
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingTaskId, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else { return }
            self.handleProcessingTask(task: processingTask)
        }
        
        // Listen to live Wi-Fi connection events
        NetworkMonitor.shared.onWifiConnected = { [weak self] in
            self?.triggerWifiAutoSync()
        }
    }
    
    public func scheduleNextBackgroundSync() {
        let cfg = SynapsConfig.load()
        guard cfg.backgroundTaskEnabled else { return }
        
        // Schedule App Refresh (every 15 minutes minimum)
        let refreshRequest = BGAppRefreshTaskRequest(identifier: Self.refreshTaskId)
        refreshRequest.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(refreshRequest)
        } catch {
            print("Could not schedule BGAppRefresh: \(error)")
        }
        
        // Schedule Heavy Processing Task (requires network + optionally power)
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
    
    /// Triggered whenever device connects to Wi-Fi
    public func triggerWifiAutoSync() {
        let cfg = SynapsConfig.load()
        guard cfg.autoSyncOnWifi else { return }
        
        Task {
            // Check if NAS is reachable
            let isOnline = await NASClient.shared.checkHealth()
            guard isOnline else { return }
            
            // Gather uncommitted items
            await PhotoLibraryService.shared.fetchAllMedia()
            let uncommitted = PhotoLibraryService.shared.mediaItems.filter { $0.syncStatus == .uncommitted || $0.syncStatus == .failed }
            
            guard !uncommitted.isEmpty else { return }
            
            // Auto commit pending uncommitted items
            SyncManager.shared.syncItems(uncommitted)
        }
    }
    
    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleNextBackgroundSync()
        
        let cfg = SynapsConfig.load()
        guard cfg.autoSyncOnWifi && NetworkMonitor.shared.isWifi else {
            task.setTaskCompleted(success: true)
            return
        }
        
        let syncOperation = Task {
            let isOnline = await NASClient.shared.checkHealth()
            guard isOnline else {
                task.setTaskCompleted(success: false)
                return
            }
            
            await PhotoLibraryService.shared.fetchAllMedia()
            let uncommitted = PhotoLibraryService.shared.mediaItems.filter { $0.syncStatus == .uncommitted }
            
            if !uncommitted.isEmpty {
                // In background refresh, sync a batch of up to 20 items to stay within budget
                let batch = Array(uncommitted.prefix(20))
                SyncManager.shared.syncItems(batch)
            }
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            syncOperation.cancel()
            SyncManager.shared.cancelSync()
        }
    }
    
    private func handleProcessingTask(task: BGProcessingTask) {
        scheduleNextBackgroundSync()
        
        let cfg = SynapsConfig.load()
        guard NetworkMonitor.shared.isWifi else {
            task.setTaskCompleted(success: true)
            return
        }
        
        let syncOperation = Task {
            let isOnline = await NASClient.shared.checkHealth()
            guard isOnline else {
                task.setTaskCompleted(success: false)
                return
            }
            
            await PhotoLibraryService.shared.fetchAllMedia()
            let uncommitted = PhotoLibraryService.shared.mediaItems.filter { $0.syncStatus == .uncommitted }
            
            if !uncommitted.isEmpty {
                SyncManager.shared.syncItems(uncommitted)
            }
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            syncOperation.cancel()
            SyncManager.shared.cancelSync()
        }
    }
}
