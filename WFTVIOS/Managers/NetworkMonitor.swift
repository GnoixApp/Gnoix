import Foundation
import Network
import Combine

enum NetworkStatus {
    case connected
    case disconnected
    case uncertain
}

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()
    
    private let monitor: NWPathMonitor
    private let monitorQueue = DispatchQueue(label: "com.wftv.networkmonitor")
    private var lastNotifiedConnectionState: Bool?
    
    @Published private(set) var status: NetworkStatus = .uncertain
    @Published private(set) var isConnected: Bool = true
    @Published private(set) var connectionType: NWInterface.InterfaceType? = nil
    
    private init() {
        monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.updateStatus(path)
            }
        }
        monitor.start(queue: monitorQueue)
    }
    
    deinit {
        monitor.cancel()
    }
    
    private func updateStatus(_ path: NWPath) {
        let wasConnected = isConnected
        isConnected = path.status == .satisfied
        connectionType = nil
        
        for interface in path.availableInterfaces {
            if interface.type == .wifi {
                connectionType = .wifi
                break
            } else if interface.type == .cellular {
                connectionType = .cellular
                break
            } else if interface.type == .wiredEthernet {
                connectionType = .wiredEthernet
                break
            }
        }
        
        if isConnected {
            status = .connected
            if path.status == .satisfied && path.usesInterfaceType(.wifi) {
                connectionType = .wifi
            } else if path.status == .satisfied && path.usesInterfaceType(.cellular) {
                connectionType = .cellular
            }
        } else {
            status = .disconnected
        }

        NotificationCenter.default.post(name: .networkStatusChanged, object: nil)

        if lastNotifiedConnectionState == nil || wasConnected != isConnected {
            if isConnected {
                NotificationCenter.default.post(name: .networkReconnected, object: nil)
            } else {
                NotificationCenter.default.post(name: .networkDisconnected, object: nil)
            }
        }
        lastNotifiedConnectionState = isConnected
    }
    
    var isOnWiFi: Bool {
        connectionType == .wifi
    }
    
    var isOnCellular: Bool {
        connectionType == .cellular
    }
    
    var isOnEthernet: Bool {
        connectionType == .wiredEthernet
    }
}

extension Notification.Name {
    static let networkStatusChanged = Notification.Name("networkStatusChanged")
    static let networkReconnected = Notification.Name("networkReconnected")
    static let networkDisconnected = Notification.Name("networkDisconnected")
}
