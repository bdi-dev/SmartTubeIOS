import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("NAS invite links")
struct NASInviteLinkTests {
    private func link(_ raw: String) throws -> NASInviteLink? {
        NASInviteLink(url: try #require(URL(string: raw)))
    }

    @Test("a well-formed invite yields the server URL and token")
    func parsesInvite() throws {
        let invite = try #require(
            try link("smarttube://nas?url=http%3A%2F%2F100.64.1.2%3A8080&token=abc123"))
        #expect(invite.serverURL == URL(string: "http://100.64.1.2:8080"))
        #expect(invite.token == "abc123")
    }

    @Test("an https server URL with a path is kept as given")
    func keepsHTTPSPath() throws {
        let invite = try #require(
            try link("smarttube://nas?url=https%3A%2F%2Fnas.example.ts.net%2Fytdlp&token=t"))
        #expect(invite.serverURL == URL(string: "https://nas.example.ts.net/ytdlp"))
    }

    @Test("whitespace around the token and URL is trimmed")
    func trimsValues() throws {
        let invite = try #require(
            try link("smarttube://nas?url=%20http%3A%2F%2Fnas.local%20&token=%20tok%0A"))
        #expect(invite.serverURL == URL(string: "http://nas.local"))
        #expect(invite.token == "tok")
    }

    @Test("a missing token is rejected")
    func missingToken() throws {
        #expect(try link("smarttube://nas?url=http%3A%2F%2Fnas.local") == nil)
    }

    @Test("an empty or blank token is rejected")
    func blankToken() throws {
        #expect(try link("smarttube://nas?url=http%3A%2F%2Fnas.local&token=") == nil)
        #expect(try link("smarttube://nas?url=http%3A%2F%2Fnas.local&token=%20%20") == nil)
    }

    @Test("a missing or non-web server URL is rejected")
    func badServerURL() throws {
        #expect(try link("smarttube://nas?token=t") == nil)
        #expect(try link("smarttube://nas?url=ftp%3A%2F%2Fnas.local&token=t") == nil)
        #expect(try link("smarttube://nas?url=javascript%3Aalert(1)&token=t") == nil)
        #expect(try link("smarttube://nas?url=http%3A%2F%2F&token=t") == nil)
    }

    @Test("other smarttube routes and schemes are not invites")
    func otherRoutes() throws {
        #expect(try link("smarttube://video/dQw4w9WgXcQ") == nil)
        #expect(try link("smarttube://watch?v=abc") == nil)
        #expect(try link("https://nas.local/?url=http%3A%2F%2Fnas.local&token=t") == nil)
    }

    @Test("accepting stores the URL and the token in the Keychain, and keeps the yt-dlp mode")
    func acceptSavesTokenAndURL() throws {
        let invite = try #require(
            try link("smarttube://nas?url=http%3A%2F%2Fnas.local%3A8080&token=secret-token"))
        let keychain = InMemoryKeychainStore()
        let defaults = try #require(UserDefaults(suiteName: "nas-invite-\(UUID().uuidString)"))
        var settings = AppSettings()
        settings.ytDlpMode = .off

        invite.accept(into: &settings, keychain: keychain, defaults: defaults)

        #expect(settings.ytDlpServerURL == URL(string: "http://nas.local:8080"))
        #expect(settings.ytDlpMode == .off)
        #expect(
            keychain.get(service: YtDlpServerConfig.keychainService, key: YtDlpServerConfig.keychainKey)
                == "secret-token")
    }
}
