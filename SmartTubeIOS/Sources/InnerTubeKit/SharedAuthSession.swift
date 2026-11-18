import Foundation
import os

// MARK: - SharedAuthSession
//
// Process-wide copy of the signed-in account's OAuth token and SAPISID, in the same spirit
// as `ActiveChannel.shared`. Several view models (ChannelViewModel, SearchViewModel, ...)
// default to a private `InnerTubeAPI()` that nothing ever called `setAuthToken` on, so their
// requests were silently signed out: channel pages carried no resume progress and the
// History fallback never ran. Instances made by the public initializer seed from this and
// publish to it; clearing the token (sign-out) clears the SAPISID as well.

public final class SharedAuthSession: Sendable {
    public static let shared = SharedAuthSession()

    private struct State {
        var token: String?
        var sapisid: String?
    }
    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    init() {}

    var token: String? { state.withLock { $0.token } }
    var sapisid: String? { state.withLock { $0.sapisid } }

    func setToken(_ token: String?) {
        state.withLock {
            $0.token = token
            if token == nil { $0.sapisid = nil }
        }
    }

    func setSAPISID(_ value: String) {
        state.withLock { $0.sapisid = value }
    }
}
