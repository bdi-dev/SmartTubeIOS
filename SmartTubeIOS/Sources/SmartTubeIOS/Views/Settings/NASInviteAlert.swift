import SmartTubeIOSCore
import SwiftUI

extension View {
    /// Asks before a `smarttube://nas` invite is saved. Shows the server host only, never the token.
    public func nasInviteAlert(_ controller: NASInviteController, settings: SettingsStore) -> some View {
        let isPresented = Binding(
            get: { controller.pending != nil },
            set: { if !$0 { controller.decline() } })
        return alert("Use this NAS server?", isPresented: isPresented, presenting: controller.pending) { _ in
            Button("Save") { controller.accept(into: settings) }
            Button("Cancel", role: .cancel) { controller.decline() }
        } message: { invite in
            Text(
                "Use the NAS server at \(invite.serverURL.host() ?? invite.serverURL.absoluteString)? "
                    + "Your personal token will be stored in this device's Keychain."
            )
        }
    }
}
