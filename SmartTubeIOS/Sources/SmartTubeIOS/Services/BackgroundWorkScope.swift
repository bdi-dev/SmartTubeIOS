import Foundation

#if os(iOS)
import UIKit
#endif

/// Keeps the process alive for a little longer after the app is woken or sent to the background,
/// so post-processing (merge / remux) can finish. UIKit lives here, not in `SmartTubeIOSCore`.
@MainActor
public protocol BackgroundWorkScope: Sendable {
    /// Begins a background task. `onExpire` runs if the system is about to suspend the app.
    /// Returns a closure that ends the task; it is safe to call more than once.
    func begin(onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

/// Production scope: `UIApplication.beginBackgroundTask` on iOS, a no-op elsewhere.
public struct SystemBackgroundWorkScope: BackgroundWorkScope {
    public init() {}

    public func begin(onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        #if os(iOS)
        let box = TaskIDBox()
        let taskID = UIApplication.shared.beginBackgroundTask(withName: "SmartTube.download.postprocess") {
            // Expiration handler runs on the main thread.
            MainActor.assumeIsolated {
                onExpire()
                box.end()
            }
        }
        box.id = taskID
        return { box.end() }
        #else
        return {}
        #endif
    }

    #if os(iOS)
    @MainActor
    private final class TaskIDBox {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
    #endif
}
