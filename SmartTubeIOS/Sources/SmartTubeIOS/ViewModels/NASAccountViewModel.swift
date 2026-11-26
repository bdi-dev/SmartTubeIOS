import Foundation
import SmartTubeIOSCore

// MARK: - NASAccountViewModel

/// Who the saved token belongs to on the NAS server, for the "Signed in as" row in Settings.
/// A server too old for `/v1/me` (404) yields `.unsupported`, which hides the row.
@MainActor
@Observable
final class NASAccountViewModel {
    enum State: Equatable {
        case idle
        case signedIn(name: String, role: YtDlpMe.Role)
        /// The server is up but does not accept the token.
        case rejected
        /// The server could not be reached.
        case unreachable
        /// The server predates `/v1/me`.
        case unsupported
    }

    private(set) var state: State = .idle

    /// Asks the server who the token belongs to. A nil client (no URL or token) resets to `.idle`.
    func load(client: (any YtDlpServerClient)?) async {
        guard let client else {
            state = .idle
            return
        }
        state = .idle
        do {
            let me = try await client.me()
            state = .signedIn(name: me.name, role: me.role)
        } catch is CancellationError {
            return
        } catch let error as YtDlpServerError where error.status == 401 {
            state = .rejected
        } catch let error as YtDlpServerError where error.status == 404 {
            state = .unsupported
        } catch {
            state = .unreachable
        }
    }
}
