import ActivityKit
import Combine
import Foundation
import UIKit

/// Mirrors a running sync on the Lock Screen and in the Dynamic Island (Live Activity).
///
/// Follows SyncManager's published progress: starts an activity when a run begins while the app
/// is in the foreground (iOS doesn't let apps start one from the background), updates it at most
/// about once a second, and ends it with a summary that stays visible for a few minutes.
/// While the app is suspended and only the background URLSession is uploading, the count can't
/// move; after a few minutes iOS marks the activity stale and it says so.
@available(iOS 16.2, *)
@MainActor
final class SyncLiveActivityController {
    static let shared = SyncLiveActivityController()
    /// Settings → "Show progress on Lock Screen" (on unless turned off).
    static let enabledKey = "showSyncOnLockScreen"

    private var activity: Activity<SyncActivityAttributes>?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private static let staleAfter: TimeInterval = 5 * 60
    private static let keepFinishedFor: TimeInterval = 5 * 60
    private static let keepStoppedFor: TimeInterval = 30 * 60

    private init() {}

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Call once at launch.
    func start() {
        guard !started else { return }
        started = true
        // A previous launch may have been killed mid-run and left an activity behind.
        for leftover in Activity<SyncActivityAttributes>.activities {
            Task { await leftover.end(nil, dismissalPolicy: .immediate) }
        }
        let sync = SyncManager.shared
        Publishers.CombineLatest4(sync.$isSyncing, sync.$syncedCount, sync.$totalToSyncCount, sync.$currentItemName)
            .combineLatest(sync.$statusMessage)
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] values, message in
                let (isSyncing, done, total, item) = values
                self?.render(isSyncing: isSyncing, done: done, total: total, item: item, message: message)
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                if !Self.isEnabled { self?.endNow() }
            }
            .store(in: &cancellables)
    }

    private func render(isSyncing: Bool, done: Int, total: Int, item: String, message: String?) {
        if isSyncing {
            let state = SyncActivityAttributes.ContentState(
                done: done, total: total,
                detail: item.isEmpty ? "Preparing..." : item,
                phase: .syncing
            )
            if let activity {
                let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter))
                Task { await activity.update(content) }
            } else {
                begin(with: state)
            }
        } else if let activity {
            self.activity = nil
            let stopped = message != nil
            let state = SyncActivityAttributes.ContentState(
                done: done, total: total,
                detail: message ?? (done == 1 ? "1 item handled." : "\(done.formatted()) items handled."),
                phase: stopped ? .stopped : .finished
            )
            let keep = stopped ? Self.keepStoppedFor : Self.keepFinishedFor
            Task {
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(keep)))
            }
        }
    }

    private func begin(with state: SyncActivityAttributes.ContentState) {
        guard Self.isEnabled,
              state.total > 0,
              ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState == .active else { return }
        do {
            activity = try Activity.request(
                attributes: SyncActivityAttributes(nasName: Self.nasName()),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(Self.staleAfter)),
                pushType: nil
            )
        } catch {
            print("Live Activity not started: \(error.localizedDescription)")
        }
    }

    private func endNow() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    /// "homecloud1" for http://homecloud1.local:8000, the IP otherwise.
    private static func nasName() -> String {
        let host = URL(string: SynapsConfig.load().nasUrl)?.host ?? "NAS"
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }
}
