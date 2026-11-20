import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - ChannelShortsRequestTests
//
// Request shape and failure behaviour of `InnerTubeAPI.fetchChannelShorts` (TVHTML5 browse of
// `VLUUSH<id>`), with no network: a URLProtocol records each request and returns a canned body.
// Also pins which channel path the auth state selects (`usesTVChannelVideos`), so the iOS
// SAPISID hand-off is covered by a test rather than by reading alone.

/// Records every POST it sees and answers with `statusCode` and `body`.
private final class ShortsStubURLProtocol: URLProtocol, @unchecked Sendable {

    nonisolated(unsafe) static var statusCode = 200
    nonisolated(unsafe) static var body: Data = Data("{}".utf8)
    nonisolated(unsafe) static var captured: [URLRequest] = []

    static func reset(statusCode: Int = 200, body: Data = Data("{}".utf8)) {
        Self.statusCode = statusCode
        Self.body = body
        Self.captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool { request.httpMethod == "POST" }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.captured.append(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: Self.statusCode, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Channel Shorts request and fallback (InnerTube)", .serialized)
struct ChannelShortsRequestTests {

    private static let channelId = "UCX6OQ3DkcsbYNE6H8uQQuVA"

    private func makeAPI(token: String? = nil, sapisid: String? = nil) async -> InnerTubeAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShortsStubURLProtocol.self]
        let api = InnerTubeAPI(authToken: token, session: URLSession(configuration: config))
        if let sapisid { await api.setSAPISID(sapisid) }
        return api
    }

    private func requestBody(_ request: URLRequest) throws -> [String: Any] {
        if let data = request.httpBody {
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("no token: TV browse of the Shorts playlist, API key in the query, no Authorization")
    func noTokenRequestShape() async throws {
        ShortsStubURLProtocol.reset(body: Data(TVChannelVideosFixtures.uploadsPlaylistPage.utf8))
        let api = await makeAPI()

        _ = try await api.fetchChannelShorts(channelId: Self.channelId)

        let request = try #require(ShortsStubURLProtocol.captured.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query?.contains("key=") == true)
        #expect(request.value(forHTTPHeaderField: "X-YouTube-Client-Name") == InnerTubeClients.TV.nameID)
        let body = try requestBody(request)
        #expect(body["browseId"] as? String == "VLUUSH" + Self.channelId.dropFirst(2))
    }

    @Test("token: the same browse is sent with Bearer auth and no API key")
    func tokenRequestShape() async throws {
        ShortsStubURLProtocol.reset(body: Data(TVChannelVideosFixtures.uploadsPlaylistPage.utf8))
        let api = await makeAPI(token: "tok")

        _ = try await api.fetchChannelShorts(channelId: Self.channelId)

        let request = try #require(ShortsStubURLProtocol.captured.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.url?.query?.contains("key=") != true)
    }

    @Test("every entry of the playlist is marked as a Short")
    func entriesAreShorts() async throws {
        ShortsStubURLProtocol.reset(body: Data(TVChannelVideosFixtures.uploadsPlaylistPage.utf8))
        let api = await makeAPI()

        let shorts = try await api.fetchChannelShorts(channelId: Self.channelId)

        #expect(shorts.count == 3)
        let allShorts = shorts.allSatisfy { $0.isShort }
        #expect(allShorts)
    }

    @Test("an empty playlist returns no Shorts rather than throwing")
    func emptyPlaylistReturnsEmpty() async throws {
        ShortsStubURLProtocol.reset(body: Data("{}".utf8))
        let api = await makeAPI()

        let shorts = try await api.fetchChannelShorts(channelId: Self.channelId)

        #expect(shorts.isEmpty)
    }

    @Test("an HTTP failure throws, and the channel view model still shows Home Shorts")
    @MainActor
    func httpFailureFallsBackInViewModel() async throws {
        ShortsStubURLProtocol.reset(statusCode: 500)
        let api = await makeAPI()

        await #expect(throws: (any Error).self) {
            _ = try await api.fetchChannelShorts(channelId: Self.channelId)
        }

        // The view model owns the fallback: it takes the throw from this same API and keeps
        // the Home-shelf Shorts without surfacing an error.
        let home = Video(id: "homeShort1", title: "Short", channelTitle: "C", isShort: true)
        let fake = FallbackChannelAPI(real: api, home: home)
        let vm = ChannelViewModel(api: fake)
        await vm.loadAsync(channelId: Self.channelId)

        #expect(vm.shorts.map(\.id) == ["homeShort1"])
        #expect(vm.error == nil)
    }

    @Test("usesTVChannelVideos: token without SAPISID uses TV; with SAPISID the WEB path is kept")
    func sapisidSelectsWebPath() async {
        let tokenOnly = await makeAPI(token: "tok")
        #expect(await tokenOnly.usesTVChannelVideos)

        let withSAPISID = await makeAPI(token: "tok", sapisid: "sid")
        #expect(await withSAPISID.usesTVChannelVideos == false)
    }
}

/// Serves the real Shorts call from `real` and a single Home Short for the rest, so the view
/// model's fallback runs on top of an API whose Shorts call really fails over HTTP.
private final class FallbackChannelAPI: InnerTubeAPIProtocol, @unchecked Sendable {
    let real: InnerTubeAPI
    let home: Video

    init(real: InnerTubeAPI, home: Video) {
        self.real = real
        self.home = home
    }

    func setAuthToken(_ token: String?) async {}
    func setSAPISID(_ value: String?) async {}
    func fetchHome(continuationToken: String?) async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchHomeRows(continuationToken: String?) async throws -> [VideoGroup] { [] }
    func fetchSubscriptions(continuationToken: String?) async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchHistory(continuationToken: String?) async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchShorts() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchShortsMore(continuationToken: String) async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchMusic() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchGaming() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchNews() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchLive() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchSports() async throws -> VideoGroup { VideoGroup(title: "", videos: []) }
    func fetchUserPlaylists() async throws -> [PlaylistInfo] { [] }
    func fetchSubscribedChannels() async throws -> [Channel] { [] }
    func fetchChannelThumbnailURL(channelId: String) async throws -> URL? { nil }
    func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        (Channel(id: channelId, title: "C"), VideoGroup(title: "", videos: [home]))
    }
    func fetchChannelVideos(channelId: String, continuationToken: String?) async throws -> VideoGroup {
        VideoGroup(title: "", videos: [])
    }
    func fetchChannelShorts(channelId: String) async throws -> [Video] {
        try await real.fetchChannelShorts(channelId: channelId)
    }
    func search(query: String, continuationToken: String?, filter: SearchFilter) async throws -> VideoGroup {
        VideoGroup(title: "", videos: [])
    }
    func fetchSearchSuggestions(query: String) async throws -> [String] { [] }
    func fetchPlaylistVideos(playlistId: String, continuationToken: String?) async throws -> VideoGroup {
        VideoGroup(title: "", videos: [])
    }
    func addToWatchLater(videoId: String) async throws -> String? { nil }
    func removeFromWatchLater(setVideoId: String) async throws {}
    func addToPlaylist(playlistId: String, videoId: String) async throws {}
    func removeFromPlaylist(playlistId: String, setVideoId: String) async throws {}
    func sendFeedback(token: String) async throws {}
    func sendFeedbackForVideo(videoId: String, iconType: String) async throws {}
}
