import Foundation

// MARK: - NASInviteLink

/// A `smarttube://nas?url=<server url>&token=<personal token>` invite, made on the admin page
/// (see the NAS multi-user plan). Parsing is pure; nothing is saved until `accept` runs, which the
/// app calls only after the user confirms.
public struct NASInviteLink: Equatable, Sendable {
    public let serverURL: URL
    public let token: String

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "smarttube", url.host?.lowercased() == "nas" else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let rawURL = value("url"), let server = URL(string: rawURL),
            let scheme = server.scheme?.lowercased(), scheme == "http" || scheme == "https",
            server.host?.isEmpty == false
        else { return nil }
        guard let token = value("token"), !token.isEmpty else { return nil }
        self.serverURL = server
        self.token = token
    }

    /// Points the settings at the invited server and stores the token in the Keychain. The yt-dlp
    /// mode is left as it is, so accepting an invite never changes how downloads behave.
    public func accept(
        into settings: inout AppSettings,
        keychain: any KeychainStore = SystemKeychainStore(),
        defaults: UserDefaults = .standard
    ) {
        settings.ytDlpServerURL = serverURL
        YtDlpServerConfig.saveToken(token, keychain: keychain, defaults: defaults)
    }
}
