import Foundation

// MARK: - YtDlpMode

/// How downloads use the user's yt-dlp companion server.
public enum YtDlpMode: String, Codable, Sendable, CaseIterable {
    /// Never use the server.
    case off
    /// Try the app's own extractor first; use the server only when that fails to find a stream.
    case fallback
    /// Always ask the server.
    case always
}

// MARK: - YtDlpServerConfig

/// Everything needed to talk to the companion server: where it is, how to authenticate, and when
/// to use it. The token is read from the Keychain, never from `AppSettings`.
public struct YtDlpServerConfig: Sendable, Equatable {
    public static let keychainService = "com.void.smarttube.ytdlp"
    public static let keychainKey = "token"

    public var mode: YtDlpMode
    public var baseURL: URL?
    public var token: String?

    public init(mode: YtDlpMode, baseURL: URL?, token: String?) {
        self.mode = mode
        self.baseURL = baseURL
        self.token = token
    }

    /// `true` when a URL and a non-empty token are both present.
    public var isConfigured: Bool { baseURL != nil && !(token ?? "").isEmpty }

    /// `true` when the server should be consulted at all.
    public var isEnabled: Bool { mode != .off && isConfigured }

    #if targetEnvironment(simulator)
    /// Unsigned simulator builds have no Keychain access, so the token would be lost. Only when
    /// compiled for the simulator, it is also kept in UserDefaults; device builds never do this.
    private static let simulatorTokenKey = "st_ytdlp_token_simulator_only"
    #endif

    /// Reads the current persisted settings plus the Keychain token.
    public static func current(
        defaults: UserDefaults = .standard, keychain: any KeychainStore = SystemKeychainStore()
    ) -> YtDlpServerConfig {
        let settings = AppSettings.loadPersisted(defaults: defaults)
        var token = keychain.get(service: keychainService, key: keychainKey)
        #if targetEnvironment(simulator)
        if token == nil { token = defaults.string(forKey: simulatorTokenKey) }
        #endif
        return YtDlpServerConfig(mode: settings.ytDlpMode, baseURL: settings.ytDlpServerURL, token: token)
    }

    public static func saveToken(
        _ token: String?, keychain: any KeychainStore = SystemKeychainStore(), defaults: UserDefaults = .standard
    ) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = (trimmed?.isEmpty ?? true) ? nil : trimmed
        keychain.set(service: keychainService, key: keychainKey, value: value)
        #if targetEnvironment(simulator)
        if let value {
            defaults.set(value, forKey: simulatorTokenKey)
        } else {
            defaults.removeObject(forKey: simulatorTokenKey)
        }
        #endif
    }
}
