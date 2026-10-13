import Foundation
import Network
import Combine

/// Point-in-time view of the network path.
public struct NetworkSnapshot: Sendable, Equatable {
    public var isConnected: Bool
    public var isWifi: Bool
    public var isWiredEthernet: Bool
    public var isCellular: Bool
    /// Personal hotspot / cellular-backed Wi-Fi, or cellular itself.
    public var isExpensive: Bool
    /// Low Data Mode.
    public var isConstrained: Bool
    
    public static let offline = NetworkSnapshot(
        isConnected: false, isWifi: false, isWiredEthernet: false,
        isCellular: false, isExpensive: false, isConstrained: false
    )
    
    public init(isConnected: Bool, isWifi: Bool, isWiredEthernet: Bool, isCellular: Bool, isExpensive: Bool, isConstrained: Bool) {
        self.isConnected = isConnected
        self.isWifi = isWifi
        self.isWiredEthernet = isWiredEthernet
        self.isCellular = isCellular
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }
    
    init(path: NWPath) {
        self.init(
            isConnected: path.status == .satisfied,
            isWifi: path.usesInterfaceType(.wifi),
            isWiredEthernet: path.usesInterfaceType(.wiredEthernet),
            isCellular: path.usesInterfaceType(.cellular),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }
    
    /// Home-network conditions for automatic uploads: Wi-Fi or Ethernet that is neither a
    /// personal hotspot (expensive) nor in Low Data Mode (constrained).
    public var isUnmeteredLAN: Bool {
        isConnected && (isWifi || isWiredEthernet) && !isExpensive && !isConstrained
    }
}

public final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    public static let shared = NetworkMonitor()
    
    // Published state is only mutated on the main thread.
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isWifi: Bool = false
    @Published public private(set) var isCellular: Bool = false
    @Published public private(set) var isConstrained: Bool = false
    @Published public private(set) var isExpensive: Bool = false
    @Published public private(set) var isUnmeteredLAN: Bool = false
    
    /// Fired on the main actor when the device moves onto an unmetered Wi-Fi/Ethernet network.
    @MainActor public var onWifiConnected: (() -> Void)?
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.synaps.ios.networkmonitor")
    private let lock = NSLock()
    private var latest: NetworkSnapshot?                                  // guarded by lock
    private var waiters: [CheckedContinuation<NetworkSnapshot, Never>] = [] // guarded by lock
    @MainActor private var previousWasUnmeteredLAN = false
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(NetworkSnapshot(path: path))
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
    
    /// Latest delivered path, or nil before NWPathMonitor's first callback.
    public var currentSnapshot: NetworkSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }
    
    /// The current path, waiting (bounded) for the first update. A cold background launch
    /// reads this before NWPathMonitor has reported anything, when the @Published flags are
    /// still at their `false` defaults.
    public func snapshot(timeout: TimeInterval = 2.0) async -> NetworkSnapshot {
        if let snap = currentSnapshot {
            return snap
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<NetworkSnapshot, Never>) in
            lock.lock()
            if let snap = latest {
                lock.unlock()
                continuation.resume(returning: snap)
                return
            }
            waiters.append(continuation)
            lock.unlock()
            queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.flushWaiters(with: nil)
            }
        }
    }
    
    private func handle(_ snap: NetworkSnapshot) {
        lock.lock()
        latest = snap
        lock.unlock()
        flushWaiters(with: snap)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.publish(snap)
            }
        }
    }
    
    private func flushWaiters(with snap: NetworkSnapshot?) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        let value = snap ?? latest ?? NetworkSnapshot(path: monitor.currentPath)
        lock.unlock()
        for waiter in pending {
            waiter.resume(returning: value)
        }
    }
    
    @MainActor
    private func publish(_ snap: NetworkSnapshot) {
        isConnected = snap.isConnected
        isWifi = snap.isWifi
        isCellular = snap.isCellular
        isConstrained = snap.isConstrained
        isExpensive = snap.isExpensive
        isUnmeteredLAN = snap.isUnmeteredLAN
        
        // Only fire on the transition onto the home network, not on every path update.
        if snap.isUnmeteredLAN && !previousWasUnmeteredLAN {
            onWifiConnected?()
        }
        previousWasUnmeteredLAN = snap.isUnmeteredLAN
    }
}
