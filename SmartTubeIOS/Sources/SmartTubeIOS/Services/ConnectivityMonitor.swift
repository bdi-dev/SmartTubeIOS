import Foundation
import Network
import Observation
import SmartTubeIOSCore

// MARK: - ConnectivityMonitor

/// Observable "is there a network?" for the UI (offline banner, open-on-Downloads). `isOnline` is
/// `nil` until the first path update arrives, so callers can wait for a real answer instead of
/// guessing. Pass `--uitesting-force-offline` to force offline in UI tests.
@MainActor
@Observable
public final class ConnectivityMonitor {
    public static let shared = ConnectivityMonitor()

    public private(set) var isOnline: Bool?
    /// `true` when the only usable route is mobile data (no Wi-Fi or Ethernet).
    public private(set) var isCellularOnly = false

    @ObservationIgnored private let monitor: NWPathMonitor?

    public init(
        forceOffline: Bool = ProcessInfo.processInfo.arguments.contains(
            OfflineLaunchPolicy.forceOfflineLaunchArgument)
    ) {
        if forceOffline {
            isOnline = false
            monitor = nil
            return
        }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let cellularOnly =
                online && path.usesInterfaceType(.cellular) && !path.usesInterfaceType(.wifi)
                && !path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.isOnline = online
                self?.isCellularOnly = cellularOnly
            }
        }
        // NWPathMonitor.start(queue:) is the API's only entry point in our deployment target.
        monitor.start(queue: DispatchQueue(label: "com.void.smarttube.connectivity"))
    }

    deinit { monitor?.cancel() }
}
