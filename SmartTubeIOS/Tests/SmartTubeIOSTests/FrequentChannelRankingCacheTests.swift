import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// Request-count tests for the Channels "Frequent" ranking: how many History pages a Channels
// open reads cold, fresh, stale, after a failed refresh and after sign-out.

private struct FakeAPIError: Error {}

/// History and subscriptions served from memory; counts every History page request.
private actor HistoryFakeAPI: InnerTubeAPIProtocol {
    var owner = "primary"
    var channels: [Channel]
    /// Flat watch history, newest first. Served `pageSize` videos per page.
    var history: [Video]
    let pageSize = 2
    var historyFails = false
    private(set) var historyRequests = 0
    private(set) var subscriptionRequests = 0

    init(channels: [Channel], history: [Video]) {
        self.channels = channels
        self.history = history
    }

    func setHistory(_ videos: [Video]) { history = videos }
    func setHistoryFails(_ fails: Bool) { historyFails = fails }
    func setOwner(_ key: String) { owner = key }

    var historyOwnerKey: String { owner }

    func fetchHistory(continuationToken: String?) async throws -> VideoGroup {
        historyRequests += 1
        if historyFails { throw FakeAPIError() }
        let offset = Int(continuationToken ?? "0") ?? 0
        let end = min(offset + pageSize, history.count)
        let videos = Array(history[offset..<end])
        return VideoGroup(videos: videos, nextPageToken: end < history.count ? "\(end)" : nil)
    }

    func fetchSubscribedChannels() async throws -> [Channel] {
        subscriptionRequests += 1
        return channels
    }

    func fetchChannelThumbnailURL(channelId: String) async throws -> URL? { nil }

    // MARK: Unused by these tests

    func setAuthToken(_ token: String?) async {}
    func setSAPISID(_ value: String?) async {}
    func fetchHome(continuationToken: String?) async throws -> VideoGroup { throw FakeAPIError() }
    func fetchHomeRows(continuationToken: String?) async throws -> [VideoGroup] { throw FakeAPIError() }
    func fetchSubscriptions(continuationToken: String?) async throws -> VideoGroup { throw FakeAPIError() }
    func fetchShorts() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchShortsMore(continuationToken: String) async throws -> VideoGroup { throw FakeAPIError() }
    func fetchMusic() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchGaming() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchNews() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchLive() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchSports() async throws -> VideoGroup { throw FakeAPIError() }
    func fetchUserPlaylists() async throws -> [PlaylistInfo] { throw FakeAPIError() }
    func fetchChannel(channelId: String) async throws -> (channel: Channel, videos: VideoGroup) {
        throw FakeAPIError()
    }
    func fetchChannelVideos(channelId: String, continuationToken: String?) async throws -> VideoGroup {
        throw FakeAPIError()
    }
    func search(query: String, continuationToken: String?, filter: SearchFilter) async throws -> VideoGroup {
        throw FakeAPIError()
    }
    func fetchSearchSuggestions(query: String) async throws -> [String] { throw FakeAPIError() }
    func fetchPlaylistVideos(playlistId: String, continuationToken: String?) async throws -> VideoGroup {
        throw FakeAPIError()
    }
    func addToWatchLater(videoId: String) async throws -> String? { throw FakeAPIError() }
    func removeFromWatchLater(setVideoId: String) async throws { throw FakeAPIError() }
    func addToPlaylist(playlistId: String, videoId: String) async throws { throw FakeAPIError() }
    func removeFromPlaylist(playlistId: String, setVideoId: String) async throws { throw FakeAPIError() }
    func sendFeedback(token: String) async throws { throw FakeAPIError() }
    func sendFeedbackForVideo(videoId: String, iconType: String) async throws { throw FakeAPIError() }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private func channel(_ n: Int) -> Channel { Channel(id: "c\(n)", title: "Channel c\(n)") }

private func watchedVideo(_ index: Int, channelN: Int) -> Video {
    Video(id: "v\(index)", title: "Video \(index)", channelTitle: "Channel c\(channelN)", channelId: "c\(channelN)")
}

/// Ten channels. History (newest first) favours c3, then c1, then c5, then c7.
/// The first six pages read 12 videos, so the cold read covers exactly that window.
private func sampleHistory() -> [Video] {
    let order = [3, 3, 3, 3, 1, 1, 1, 5, 5, 7, 7, 7] + [0, 2, 4, 6, 8, 9, 0, 2, 4, 6]
    return order.enumerated().map { watchedVideo($0.offset, channelN: $0.element) }
}

@MainActor
@Suite("Frequent channel ranking cache")
struct FrequentChannelRankingCacheTests {

    private func makeViewModel(
        api: HistoryFakeAPI, cache: FrequentChannelHistoryCache
    ) -> BrowseViewModel {
        let localDefaults = UserDefaults(suiteName: "freq-local-\(UUID().uuidString)")!
        return BrowseViewModel(
            api: api,
            initialSection: BrowseSection(type: .channels),
            localHistory: LocalWatchHistoryStore(defaults: localDefaults),
            rankingHistory: cache)
    }

    /// One Channels open: signed in, loads subscriptions, ranks. Awaits the ranking.
    private func openChannels(_ vm: BrowseViewModel) async {
        await vm.updateAuthToken("token")
        await vm.waitForFrequentRanking()
    }

    private func makeCache(clock: TestClock, dir: URL? = nil) -> FrequentChannelHistoryCache {
        FrequentChannelHistoryCache(ttl: 15 * 60, directory: dir, now: { clock.now })
    }

    @Test func coldOpenReadsSixHistoryPagesAndRanksByThem() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let vm = makeViewModel(api: api, cache: makeCache(clock: clock))

        await openChannels(vm)

        #expect(await api.historyRequests == 6)
        #expect(await api.subscriptionRequests == 1)
        #expect(vm.subscribedChannels.first?.id == "c3")
        // c3, c1, c5, c7 are the watched channels in the read window.
        #expect(vm.frequentChannelCount == 4)
    }

    @Test func freshReopenMakesNoHistoryRequests() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let vm = makeViewModel(api: api, cache: makeCache(clock: clock))
        await openChannels(vm)
        let coldRequests = await api.historyRequests

        clock.now.addTimeInterval(60)  // a minute later, still fresh
        await openChannels(vm)

        #expect(await api.historyRequests == coldRequests)
        #expect(vm.subscribedChannels.first?.id == "c3")
        #expect(vm.frequentChannelCount == 4)
    }

    @Test func staleReopenRefreshesAndReranksWhenTopChanges() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let vm = makeViewModel(api: api, cache: makeCache(clock: clock))
        await openChannels(vm)
        #expect(vm.subscribedChannels.first?.id == "c3")
        let coldRequests = await api.historyRequests

        // Watching c9 a lot changes the top group. The cache is now stale.
        let newer = (0..<6).map { watchedVideo(100 + $0, channelN: 9) } + sampleHistory()
        await api.setHistory(newer)
        clock.now.addTimeInterval(16 * 60)
        await openChannels(vm)

        #expect(await api.historyRequests == coldRequests + 6)
        #expect(vm.subscribedChannels.first?.id == "c9")
    }

    @Test func failedRefreshKeepsCachedRanking() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let cache = makeCache(clock: clock)
        let vm = makeViewModel(api: api, cache: cache)
        await openChannels(vm)

        clock.now.addTimeInterval(16 * 60)
        await api.setHistoryFails(true)
        await openChannels(vm)

        #expect(vm.subscribedChannels.first?.id == "c3")
        #expect(vm.frequentChannelCount == 4)
        #expect(!(await cache.snapshot(ownerKey: "primary")).watches.isEmpty)
    }

    @Test func signOutClearsCacheSoNextOpenIsCold() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let cache = makeCache(clock: clock)
        let vm = makeViewModel(api: api, cache: cache)
        await openChannels(vm)
        let coldRequests = await api.historyRequests

        await vm.updateAuthToken(nil)
        await vm.waitForFrequentRanking()
        #expect((await cache.snapshot(ownerKey: "primary")).watches.isEmpty)
        #expect(vm.frequentChannelCount == 0)

        await openChannels(vm)
        #expect(await api.historyRequests == coldRequests + 6)
    }

    @Test func otherAccountDoesNotReuseCachedHistory() async {
        let api = HistoryFakeAPI(channels: (0..<10).map(channel), history: sampleHistory())
        let clock = TestClock()
        let vm = makeViewModel(api: api, cache: makeCache(clock: clock))
        await openChannels(vm)
        let coldRequests = await api.historyRequests

        await api.setOwner("brand-2")
        clock.now.addTimeInterval(60)  // fresh for the first account, but a different owner
        await openChannels(vm)

        #expect(await api.historyRequests == coldRequests + 6)
    }
}
