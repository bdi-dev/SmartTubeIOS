import Foundation
import SmartTubeIOSCore

// MARK: - NASInviteController

/// Holds a `smarttube://nas` invite until the user confirms it. Nothing is saved on receipt: the
/// settings and Keychain change only in `accept`, which the confirmation alert calls.
@MainActor
@Observable
public final class NASInviteController {
    public private(set) var pending: NASInviteLink?

    public init() {}

    public func receive(_ invite: NASInviteLink) {
        pending = invite
    }

    public func decline() {
        pending = nil
    }

    public func accept(into store: SettingsStore) {
        guard let invite = pending else { return }
        var settings = store.settings
        invite.accept(into: &settings)
        store.settings = settings
        pending = nil
    }
}
