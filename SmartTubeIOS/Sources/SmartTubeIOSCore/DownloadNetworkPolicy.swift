import Foundation

/// Why running downloads are being held (suspended) right now.
public enum DownloadHoldReason: Sendable, Equatable {
    /// The user turned downloads off.
    case disabled
    /// Mobile data is not allowed and the device is on it.
    case waitingForWiFi
}

/// Pure decision: should downloads be held, given the two settings and the current connection?
public enum DownloadNetworkPolicy {
    public static func holdReason(
        downloadsEnabled: Bool, allowCellular: Bool, onCellularOnly: Bool
    ) -> DownloadHoldReason? {
        if !downloadsEnabled { return .disabled }
        if !allowCellular && onCellularOnly { return .waitingForWiFi }
        return nil
    }
}
