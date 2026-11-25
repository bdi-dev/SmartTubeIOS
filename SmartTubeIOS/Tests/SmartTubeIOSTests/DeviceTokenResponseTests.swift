import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("DeviceTokenResponse")
struct DeviceTokenResponseTests {
    private func classify(_ status: Int, _ body: String) -> DeviceTokenResponse {
        DeviceTokenResponse.classify(statusCode: status, data: Data(body.utf8))
    }

    @Test("the RFC 8628 polling answers keep their meaning")
    func rfcAnswers() {
        #expect(classify(400, #"{"error":"authorization_pending"}"#) == .authorizationPending)
        #expect(classify(400, #"{"error":"slow_down"}"#) == .slowDown)
        #expect(classify(400, #"{"error":"access_denied"}"#) == .accessDenied)
        #expect(classify(400, #"{"error":"expired_token"}"#) == .expired)
    }

    @Test("a good response yields the tokens")
    func success() {
        let result = classify(200, #"{"access_token":"a","refresh_token":"r","expires_in":3599}"#)
        #expect(result == .tokens(.init(accessToken: "a", refreshToken: "r", expiresIn: 3599)))
    }

    @Test("server errors, rate limits and non-JSON bodies are retried, not fatal")
    func transient() {
        #expect(classify(503, "<html>Service Unavailable</html>") == .transient("HTTP 503, body is not JSON"))
        #expect(classify(200, "") == .transient("HTTP 200, body is not JSON"))
        #expect(classify(429, #"{"error":"rate_limit_exceeded"}"#) == .transient("rate_limit_exceeded"))
        #expect(classify(400, #"{"error":"temporarily_unavailable"}"#) == .transient("temporarily_unavailable"))
        #expect(classify(500, #"{"error":"something_new"}"#) == .transient("something_new"))
        #expect(classify(502, #"{"unexpected":true}"#) == .transient("HTTP 502"))
    }

    @Test("bad client credentials and unknown errors stay fatal, with the code kept for the log")
    func permanent() {
        #expect(classify(401, #"{"error":"invalid_client"}"#) == .permanent("invalid_client"))
        #expect(classify(400, #"{"error":"invalid_grant"}"#) == .permanent("invalid_grant"))
        #expect(classify(200, #"{"foo":"bar"}"#) == .permanent("HTTP 200, no access_token"))
    }
}
