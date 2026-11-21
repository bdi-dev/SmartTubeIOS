import Foundation

// MARK: - OfflineLaunchPolicy

/// Decides whether the app should open on the Downloads tab because the device is offline.
/// Pure and side-effect free; the view layer applies the answer at most once per launch.
public enum OfflineLaunchPolicy {
    /// UI-test launch argument that makes the app behave as if there were no network.
    public static let forceOfflineLaunchArgument = "--uitesting-force-offline"

    /// Open Downloads when we know we are offline, something playable is saved, and we have not
    /// already done this for the current launch.
    public static func shouldOpenDownloads(
        isOnline: Bool?, hasCompleteDownloads: Bool, alreadyApplied: Bool
    ) -> Bool {
        guard !alreadyApplied, hasCompleteDownloads else { return false }
        return isOnline == false
    }
}
