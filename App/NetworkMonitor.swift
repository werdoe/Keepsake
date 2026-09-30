import Foundation
import Network

/// Tracks whether the phone is on Wi-Fi, mobile data, or offline.
final class NetworkMonitor: ObservableObject {
    enum Kind { case wifi, cellular, other, offline }

    static let shared = NetworkMonitor()

    @Published private(set) var kind: Kind = .other

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let kind: Kind
            if path.status != .satisfied {
                kind = .offline
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                kind = .wifi
            } else if path.usesInterfaceType(.cellular) {
                kind = .cellular
            } else {
                kind = .other
            }
            DispatchQueue.main.async { self?.kind = kind }
        }
        monitor.start(queue: DispatchQueue(label: "keepsake.network"))
    }

    var label: String {
        switch kind {
        case .wifi: return "On Wi-Fi"
        case .cellular: return "On mobile data"
        case .other: return "Connected"
        case .offline: return "Offline"
        }
    }

    var symbol: String {
        switch kind {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other: return "network"
        case .offline: return "wifi.slash"
        }
    }
}
