import Foundation
import Network
import Combine

public final class NetworkMonitor: ObservableObject, @unchecked Sendable {
    public static let shared = NetworkMonitor()
    
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var isWifi: Bool = false
    @Published public private(set) var isCellular: Bool = false
    @Published public private(set) var isConstrained: Bool = false
    @Published public private(set) var isExpensive: Bool = false
    
    public var onWifiConnected: (() -> Void)?
    
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.synaps.ios.networkmonitor")
    private var previousWasWifi = false
    
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            let wifi = path.usesInterfaceType(.wifi)
            let cellular = path.usesInterfaceType(.cellular)
            let constrained = path.isConstrained
            let expensive = path.isExpensive
            
            DispatchQueue.main.async {
                self.isConnected = connected
                self.isWifi = wifi
                self.isCellular = cellular
                self.isConstrained = constrained
                self.isExpensive = expensive
                
                // If just switched onto Wi-Fi, trigger auto-sync callback
                if wifi && connected && !self.previousWasWifi {
                    self.onWifiConnected?()
                }
                self.previousWasWifi = wifi && connected
            }
        }
        monitor.start(queue: queue)
    }
    
    deinit {
        monitor.cancel()
    }
}
