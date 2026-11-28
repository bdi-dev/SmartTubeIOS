import Foundation
import SmartTubeIOSCore

// MARK: - NASStatusViewModel

/// The NAS status snapshot shown by the Downloads info sheet and the Settings NAS page. Read-only.
/// It checks once when shown and again on refresh; there is no background polling.
@MainActor
@Observable
final class NASStatusViewModel {
    enum State: Equatable {
        /// No reply yet.
        case loading
        case loaded(YtDlpServerStatus)
        /// The server could not be reached or sent an unreadable reply. Carries a one-line reason.
        case unreachable(String)
        /// The server predates `/v1/status` (404).
        case serverTooOld
        /// The server is up but does not accept the token (401).
        case rejected
    }

    private(set) var state: State = .loading
    /// When the last check finished, whatever its result. Nil before the first check.
    private(set) var checkedAt: Date?
    /// Round trip of the last check in milliseconds, or nil when the last check failed.
    private(set) var roundTripMilliseconds: Int?

    private let client: any YtDlpServerClient

    init(client: any YtDlpServerClient) {
        self.client = client
    }

    /// Checks the server when the screen appears.
    func load() async {
        await check()
    }

    /// Checks again on demand (toolbar button or pull to refresh). The last loaded snapshot stays
    /// on screen until the new reply arrives, so the page does not flash.
    func refresh() async {
        await check()
    }

    private func check() async {
        let clock = ContinuousClock()
        let started = clock.now
        do {
            let status = try await client.status()
            roundTripMilliseconds = Int(started.duration(to: clock.now) / .milliseconds(1))
            state = .loaded(status)
        } catch is CancellationError {
            return
        } catch let error as YtDlpServerError where error.status == 401 {
            roundTripMilliseconds = nil
            state = .rejected
        } catch let error as YtDlpServerError where error.status == 404 {
            roundTripMilliseconds = nil
            state = .serverTooOld
        } catch {
            roundTripMilliseconds = nil
            state = .unreachable(error.localizedDescription)
        }
        checkedAt = Date()
    }
}
