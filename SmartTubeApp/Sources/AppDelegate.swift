#if os(iOS)
import UIKit
import OSLog
import SmartTubeIOS

private let appDelegateLog = Logger(subsystem: "com.void.smarttube.app", category: "AppDelegate")

/// Provides the per-screen orientation mask that UIKit queries on every
/// orientation-change event. Returns `.allButUpsideDown` so that
/// `UIWindowScene.requestGeometryUpdate` can successfully request landscape
/// when the player opens and portrait when it closes. Proactive
/// portrait↔landscape transitions are managed by `OrientationManager`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        // Return .allButUpsideDown at all times so that:
        // 1. UIKit's intersection with the view controller hierarchy does not
        //    restrict to portrait-only while the full-screen player cover is
        //    being presented (PresentationHostingController caches the supported
        //    mask at creation time, before PlayerView.onAppear fires).
        // 2. OrientationManager.requestGeometryUpdate can successfully request
        //    landscape when the player opens and portrait when it closes.
        // Proactive portrait↔landscape transitions are still managed by
        // OrientationManager via UIWindowScene.requestGeometryUpdate.
        let mask = UIInterfaceOrientationMask.allButUpsideDown
        appDelegateLog.notice(
            "[AppDelegate] supportedInterfaceOrientationsFor — returning mask=\(mask.rawValue) playerIsActive=\(OrientationManager.shared.playerIsActive)"
        )
        return mask
    }

    /// The system relaunched (or woke) the app because background downloads have events for us.
    /// Touching `shared` re-creates the background session with the stored identifier, which makes
    /// the system deliver those events to its delegate; the handler is stashed and called once
    /// `urlSessionDidFinishEvents(forBackgroundURLSession:)` has been relayed to the service.
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        appDelegateLog.notice("[AppDelegate] handleEventsForBackgroundURLSession id=\(identifier, privacy: .public)")
        BackgroundDownloadSession.shared.handleEventsForBackgroundSession(
            identifier: identifier, completionHandler: completionHandler)
    }
}
#endif
