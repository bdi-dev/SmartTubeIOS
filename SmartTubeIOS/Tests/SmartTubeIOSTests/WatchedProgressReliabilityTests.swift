import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - TV channel videos (OAuth-only sessions)
//
// Fixtures: `TVChannelVideosFixtures.uploadsPlaylistPage` is a REAL signed-out capture.
// Resume-progress tiles are SHAPE-BASED (a populated percent cannot be captured signed
// out); the shape matches the TVHTML5 tileRenderer used by History/Home/Subscriptions.

@Suite("TVHTML5 channel videos")
struct TVChannelVideosTests {

    private func realPage() throws -> [String: Any] {
        let data = Data(TVChannelVideosFixtures.uploadsPlaylistPage.utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("real capture: tiles parse with duration, views, posted time; no progress signed out")
    func realCapture() async throws {
        let api = InnerTubeAPI()
        let group = try await api.parseVideoGroupForTesting(try realPage(), title: nil)
        #expect(group.videos.count == 3)
        let first = try #require(group.videos.first)
        #expect(first.id == "q6fgVVmdpgY")
        #expect(first.title == "$250,000 Hunger Games In Real Life")
        #expect(first.duration == TimeInterval(2038))
        #expect(first.viewCount != nil)
        #expect(first.publishedTimeText == "4 days ago")
        #expect(first.isShort == false)
        #expect(group.videos.allSatisfy { $0.watchProgress == nil })
        #expect(group.nextPageToken == "CONT_TOKEN_1")
    }

    @Test("channelVideoGroup drops synthetic-playlist tokens, sets UC id, tags the token")
    func normalisation() async throws {
        let api = InnerTubeAPI()
        let raw = try await api.parseVideoGroupForTesting(try realPage(), title: nil)
        let g = InnerTubeAPI.channelVideoGroup(raw, channelId: "UCX6OQ3DkcsbYNE6H8uQQuVA")
        #expect(g.videos.allSatisfy { $0.setVideoId == nil && $0.playlistId == nil && $0.playlistIndex == nil })
        #expect(g.videos.allSatisfy { $0.channelId == "UCX6OQ3DkcsbYNE6H8uQQuVA" })
        #expect(g.nextPageToken == "tvch:CONT_TOKEN_1")
    }

    @Test("uploads playlist browse id is VL + UULF + id without UC")
    func browseId() {
        #expect(InnerTubeAPI.channelUploadsBrowseId(channelId: "UCX6OQ3DkcsbYNE6H8uQQuVA") == "VLUULFX6OQ3DkcsbYNE6H8uQQuVA")
        #expect(InnerTubeAPI.isChannelId("UCabc"))
        #expect(!InnerTubeAPI.isChannelId("@handle"))
        #expect(!InnerTubeAPI.isChannelId("UC"))
    }

    private func tile(_ id: String, percent: Any?) -> [String: Any] {
        var overlays: [[String: Any]] = [
            ["thumbnailOverlayTimeStatusRenderer": ["text": ["simpleText": "10:00"], "style": "DEFAULT"]]
        ]
        if let percent { overlays.append(["thumbnailOverlayResumePlaybackRenderer": ["percentDurationWatched": percent]]) }
        return [
            "tileRenderer": [
                "contentType": "TILE_CONTENT_TYPE_VIDEO",
                "contentId": id,
                "header": ["tileHeaderRenderer": ["thumbnailOverlays": overlays]],
                "metadata": ["tileMetadataRenderer": ["title": ["simpleText": id]]],
                "onSelectCommand": ["watchEndpoint": ["videoId": id]],
            ]
        ]
    }

    @Test("SHAPE-BASED: resume overlay maps percent to 0...1 (Int and Double)")
    func resumeOverlay() async throws {
        let json: [String: Any] = [
            "contents": [
                "playlistVideoListRenderer": [
                    "contents": [tile("A", percent: 45), tile("B", percent: 100), tile("C", percent: 12.5), tile("D", percent: nil)]
                ]
            ]
        ]
        let g = try await InnerTubeAPI().parseVideoGroupForTesting(json, title: nil)
        #expect(g.videos.map(\.watchProgress) == [0.45, 1.0, 0.125, nil])
    }

    @Test("TV path is used only with an OAuth token and no SAPISID")
    func eligibility() async {
        let none = InnerTubeAPI(authToken: nil, session: .shared)
        #expect(await none.usesTVChannelVideos == false)
        let oauth = InnerTubeAPI(authToken: "t", session: .shared)
        #expect(await oauth.usesTVChannelVideos == true)
        await oauth.setSAPISID("sid")
        #expect(await oauth.usesTVChannelVideos == false)
    }
}

// MARK: - Progress precedence

@Suite("Watch progress precedence")
struct WatchProgressPolicyTests {
    @Test("a full remote watch beats a 2-minute local watch")
    func remoteWins() {
        #expect(WatchProgressPolicy.combined(1.0, nil, 0.03) == 1.0)
    }

    @Test("local watch shows when YouTube has nothing")
    func localOnly() {
        #expect(WatchProgressPolicy.combined(nil, nil, 0.4) == 0.4)
    }

    @Test("larger local watch than remote wins")
    func localLarger() {
        #expect(WatchProgressPolicy.combined(0.2, nil, 0.7) == 0.7)
    }

    @Test("history signal participates")
    func history() {
        #expect(WatchProgressPolicy.combined(nil, 1.0, 0.1) == 1.0)
    }

    @Test("no signal, clamping, NaN")
    func edges() {
        #expect(WatchProgressPolicy.combined(nil, nil, nil) == nil)
        #expect(WatchProgressPolicy.combined(2.0, nil, nil) == 1.0)
        #expect(WatchProgressPolicy.combined(Double.nan, nil, 0.2) == 0.2)
    }

    @Test("remote played reaches the watched threshold")
    func playedThreshold() {
        var v = Video(id: "A", title: "a", channelTitle: "c")
        v.watchProgress = WatchedHistoryIndex.playedFallbackProgress
        #expect(v.isWatched(threshold: 0.9))
    }
}

// MARK: - Deep, persistent history index

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _n = 0
    private var _t = Date(timeIntervalSince1970: 0)
    var n: Int { lock.withLock { _n } }
    func bump() { lock.withLock { _n += 1 } }
    var date: Date { get { lock.withLock { _t } } set { lock.withLock { _t = newValue } } }
}

@Suite("WatchedHistoryIndex deep loading")
struct WatchedHistoryIndexDeepTests {

    /// `total` pages of 5 ids each: page i holds ids "p<i>-0"..."p<i>-4".
    private func fetcher(total: Int, counter: Counter) -> WatchedHistoryIndex.PageFetcher {
        { token in
            counter.bump()
            let i = token.flatMap { Int($0) } ?? 0
            var ids: [String: Double] = [:]
            for k in 0..<5 { ids["p\(i)-\(k)"] = (k == 0) ? 0.25 : 1.0 }
            return .init(ids: ids, next: i + 1 < total ? String(i + 1) : nil)
        }
    }

    @Test("first paint loads only the initial pages; background deepens to completion")
    func lazyDeepening() async {
        let c = Counter()
        let idx = WatchedHistoryIndex(initialPages: 3, now: { c.date })
        let f = fetcher(total: 8, counter: c)
        let snap = await idx.warm(ownerKey: "u", fetch: f)
        #expect(snap.entries.count == 15)
        #expect(snap.complete == false)
        #expect(c.n == 3)
        await idx.deepenInBackground(ownerKey: "u", fetch: f)
        await idx.waitForIdle()
        let after = await idx.snapshot(ownerKey: "u")
        #expect(after.entries.count == 40)
        #expect(after.complete)
        #expect(await idx.progress(for: "p7-0") == 0.25)  // partial progress kept
        #expect(await idx.progress(for: "p7-1") == 1.0)
    }

    @Test("caps stop deepening and mark the index complete")
    func caps() async {
        let c = Counter()
        let idx = WatchedHistoryIndex(maxEntries: 20, maxPages: 6, initialPages: 2, now: { c.date })
        let f = fetcher(total: 100, counter: c)
        _ = await idx.warm(ownerKey: "u", fetch: f)
        await idx.deepenInBackground(ownerKey: "u", fetch: f)
        await idx.waitForIdle()
        let s = await idx.snapshot(ownerKey: "u")
        #expect(s.complete)
        #expect(s.pagesLoaded <= 6)
        #expect(c.n <= 6)
    }

    @Test("fresh index is not reloaded; stale one is served immediately and refreshed")
    func ttl() async {
        let c = Counter()
        let idx = WatchedHistoryIndex(ttl: 100, initialPages: 1, now: { c.date })
        let f = fetcher(total: 1, counter: c)
        _ = await idx.warm(ownerKey: "u", fetch: f)
        _ = await idx.warm(ownerKey: "u", fetch: f)
        #expect(c.n == 1)
        c.date = Date(timeIntervalSince1970: 500)
        let stale = await idx.warm(ownerKey: "u", fetch: f)
        #expect(stale.entries.count == 5)  // served immediately
        await idx.waitForIdle()
        #expect(c.n == 2)
    }

    @Test("accounts are isolated and reset clears everything")
    func isolation() async {
        let c = Counter()
        let idx = WatchedHistoryIndex(initialPages: 1, now: { c.date })
        let f = fetcher(total: 1, counter: c)
        _ = await idx.warm(ownerKey: "a", fetch: f)
        #expect(await idx.snapshot(ownerKey: "b").entries.isEmpty)
        _ = await idx.warm(ownerKey: "a", fetch: f)
        await idx.reset()
        #expect(await idx.snapshot(ownerKey: "a").entries.isEmpty)
    }

    @Test("failed initial load is not cached and is retried")
    func failure() async {
        struct E: Error {}
        let c = Counter()
        let idx = WatchedHistoryIndex(initialPages: 1, now: { c.date })
        let bad: WatchedHistoryIndex.PageFetcher = { _ in c.bump(); throw E() }
        #expect(await idx.warm(ownerKey: "u", fetch: bad).entries.isEmpty)
        #expect(await idx.warm(ownerKey: "u", fetch: bad).entries.isEmpty)
        #expect(c.n == 2)
    }

    @Test("persists per account and restores after a 'relaunch'")
    func persistence() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = Counter()
        let f = fetcher(total: 2, counter: c)
        let first = WatchedHistoryIndex(initialPages: 3, persistenceDirectory: dir, now: { c.date })
        _ = await first.warm(ownerKey: "acct", fetch: f)
        #expect(c.n == 2)
        // New instance == relaunch: entries come from disk with no network.
        let second = WatchedHistoryIndex(initialPages: 3, persistenceDirectory: dir, now: { c.date })
        let snap = await second.snapshot(ownerKey: "acct")
        #expect(snap.entries.count == 10)
        #expect(snap.complete)
        #expect(c.n == 2)
        // Another account does not see it.
        #expect(await second.snapshot(ownerKey: "other").entries.isEmpty)
        // reset() deletes the file.
        await second.reset()
        let third = WatchedHistoryIndex(persistenceDirectory: dir, now: { c.date })
        #expect(await third.snapshot(ownerKey: "acct").entries.isEmpty)
    }

    @Test("merge: remote history supersedes smaller progress, never lowers it")
    func merge() {
        var a = Video(id: "A", title: "a", channelTitle: "c"); a.watchProgress = 0.02
        var b = Video(id: "B", title: "b", channelTitle: "c"); b.watchProgress = 0.9
        let c = Video(id: "C", title: "c", channelTitle: "c")
        let d = Video(id: "D", title: "d", channelTitle: "c")
        let out = WatchedHistoryIndex.merge([a, b, c, d], index: ["A": 1.0, "B": 0.5, "C": 0.3])
        #expect(out.map(\.watchProgress) == [1.0, 0.9, 0.3, nil])
    }
}
