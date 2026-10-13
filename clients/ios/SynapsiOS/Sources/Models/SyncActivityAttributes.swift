import ActivityKit
import Foundation

/// The Live Activity shown on the Lock Screen and in the Dynamic Island while photos back up to
/// the NAS. Compiled into both the app (which starts and updates it) and the SynapsSyncActivity
/// widget extension (which draws it).
@available(iOS 16.1, *)
public struct SyncActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public enum Phase: String, Codable, Hashable {
            case syncing
            case finished
            case stopped
        }

        /// Items handled so far in this run (committed, linked or failed).
        public var done: Int
        public var total: Int
        /// What the sync is working on ("Uploading IMG_1234.HEIC..."), or a short outcome.
        public var detail: String
        public var phase: Phase

        public init(done: Int, total: Int, detail: String, phase: Phase) {
            self.done = done
            self.total = total
            self.detail = detail
            self.phase = phase
        }

        public var fraction: Double {
            total > 0 ? min(1, Double(done) / Double(total)) : 0
        }

        public var percentText: String {
            "\(Int((fraction * 100).rounded(.down)))%"
        }
    }

    /// Host name of the NAS, shown as the destination ("to homecloud1").
    public var nasName: String

    public init(nasName: String) {
        self.nasName = nasName
    }
}
