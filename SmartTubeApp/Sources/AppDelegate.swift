#if os(iOS)
import UIKit
import OSLog
import SmartTubeIOS
import SmartTubeIOSCore
import UserNotifications

private let appDelegateLog = Logger(subsystem: "com.void.smarttube.app", category: "AppDelegate")

/// Provides the per-screen orientation mask that UIKit queries on every
/// orientation-change event. Returns `.allButUpsideDown` so that
/// `UIWindowScene.requestGeometryUpdate` can successfully request landscape
/// when the player opens and portrait when it closes. Proactive
/// portrait↔landscape transitions are managed by `OrientationManager`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // New-upload alerts: the BGAppRefresh handler must be registered before launch finishes.
        NewUploadNotifier.registerBackgroundRefresh {
            let notifier = NewUploadNotifier(api: InnerTubeAPI())
            await notifier.checkIfDue(settings: SettingsStore().settings, force: true)
        }
        return true
    }

    /// Show an alert even if the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Tapping a new-upload alert opens that video via the app's own URL scheme.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard let videoId = response.notification.request.content.userInfo["videoId"] as? String,
            let url = URL(string: "smarttube://video/\(videoId)")
        else { return }
        await UIApplication.shared.open(url)
    }

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
