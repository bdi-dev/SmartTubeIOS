import Foundation

/// What Google's token endpoint said to one device-code poll (RFC 8628 §3.5), separated from the
/// networking so it can be tested. Only transient answers may be retried: treating a 5xx, an HTML
/// error page or a rate limit as a failed sign-in ends an otherwise valid attempt.
public enum DeviceTokenResponse: Equatable, Sendable {
    public struct Tokens: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
    }

    case tokens(Tokens)
    case authorizationPending
    case slowDown
    case accessDenied
    case expired
    /// Worth retrying on the next poll: a server error, rate limit, or a body that is not JSON.
    case transient(String)
    /// Will not succeed on retry (bad client credentials, unknown error). Carries the OAuth error
    /// code, or the HTTP status when there is none, for the log.
    case permanent(String)

    /// OAuth error codes that mean "try again", not "this attempt is dead".
    static let transientCodes: Set<String> = [
        "temporarily_unavailable", "server_error", "internal_failure", "rate_limit_exceeded",
        "backend_error",
    ]

    public static func classify(statusCode: Int, data: Data) -> DeviceTokenResponse {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let json else {
            // Not JSON: a gateway error page, an empty body or a captive portal.
            return .transient("HTTP \(statusCode), body is not JSON")
        }
        if let code = json["error"] as? String {
            switch code {
            case "authorization_pending": return .authorizationPending
            case "slow_down": return .slowDown
            case "access_denied": return .accessDenied
            case "expired_token": return .expired
            default:
                if transientCodes.contains(code) || statusCode >= 500 || statusCode == 429 {
                    return .transient(code)
                }
                return .permanent(code)
            }
        }
        if statusCode == 429 || statusCode >= 500 { return .transient("HTTP \(statusCode)") }
        guard (200..<300).contains(statusCode), let access = json["access_token"] as? String else {
            return .permanent("HTTP \(statusCode), no access_token")
        }
        return .tokens(
            Tokens(
                accessToken: access, refreshToken: json["refresh_token"] as? String,
                expiresIn: json["expires_in"] as? TimeInterval))
    }
}
