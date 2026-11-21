import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

private func v(_ id: String, channel: String = "c1", live: Bool = false) -> Video {
    var video = Video(id: id, title: "T \(id)", channelTitle: "Chan", thumbnailURL: nil, duration: 100)
    video.channelId = channel
    video.isLive = live
    return video
}

@Suite("NewUploadDetector")
struct NewUploadDetectorTests {
    @Test("the first check records a baseline and announces nothing")
    func baselineIsSilent() {
        let r = NewUploadDetector.evaluate(feed: [v("a"), v("b")], seenIds: [], hasBaseline: false)
        #expect(r.toNotify.isEmpty)
        #expect(r.allIds == ["a", "b"])
    }

    @Test("after the baseline only unseen, non-live, non-muted videos are announced, capped")
    func announcesNew() {
        let feed = [v("n1"), v("old"), v("live", live: true), v("muted", channel: "bad"), v("n2"), v("n3")]
        let r = NewUploadDetector.evaluate(
            feed: feed, seenIds: ["old"], hasBaseline: true, isMuted: { $0.channelId == "bad" }, limit: 2)
        #expect(r.toNotify.map(\.id) == ["n1", "n2"])
        #expect(r.allIds.count == 6)
    }

    @Test("duplicates in one feed are announced once")
    func dedupes() {
        let r = NewUploadDetector.evaluate(feed: [v("x"), v("x")], seenIds: [], hasBaseline: true)
        #expect(r.toNotify.map(\.id) == ["x"])
    }
}

@Suite("SeenUploadsStore")
struct SeenUploadsStoreTests {
    @Test("markSeen sets the baseline, dedupes, and persists across instances")
    func persists() async {
        let suite = "test-\(UUID().uuidString)"
        let store = SeenUploadsStore(suiteName: suite)
        #expect(await store.hasBaseline() == false)
        await store.markSeen(["a", "b", "a"])
        #expect(await store.hasBaseline())
        #expect(await store.seenIds() == ["a", "b"])
        let reopened = SeenUploadsStore(suiteName: suite)
        #expect(await reopened.seenIds() == ["a", "b"])
        #expect(await reopened.hasBaseline())
    }

    @Test("an empty feed does not establish the baseline")
    func emptyFeedIsNotABaseline() async {
        let store = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        await store.markSeen([])
        #expect(await store.hasBaseline() == false)
        await store.markSeen(["a"])
        #expect(await store.hasBaseline())
    }

    @Test("the list is capped, dropping the oldest ids")
    func capped() async {
        let store = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        await store.markSeen((0..<(SeenUploadsStore.maxEntries + 5)).map { "id\($0)" })
        let seen = await store.seenIds()
        #expect(seen.count == SeenUploadsStore.maxEntries)
        #expect(!seen.contains("id0"))
        #expect(seen.contains("id\(SeenUploadsStore.maxEntries + 4)"))
    }
}

@Suite("SeenUploadsStore sources")
struct SeenUploadsStoreSourceTests {
    @Test("baselines are tracked per source")
    func perSource() async {
        let store = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        await store.markSeen(["a"], source: "local")
        #expect(await store.hasBaseline(for: "local"))
        #expect(await store.hasBaseline(for: "subscriptions") == false)
    }

    @Test("the earlier single-baseline format decodes as the local source")
    func legacyDecode() async throws {
        let suite = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data(#"{"seen":["x"],"hasBaseline":true}"#.utf8), forKey: "st_seen_uploads")
        let store = SeenUploadsStore(suiteName: suite)
        #expect(await store.hasBaseline(for: "local"))
        #expect(await store.hasBaseline(for: "subscriptions") == false)
        #expect(await store.seenIds() == ["x"])
    }
}
