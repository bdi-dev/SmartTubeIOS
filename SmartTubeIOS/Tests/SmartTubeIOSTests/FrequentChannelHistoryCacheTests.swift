import Foundation
import Testing

@testable import SmartTubeIOSCore

/// Shared mutable clock for the cache (the cache reads `now` from its actor context).
private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("freq-\(UUID().uuidString)", isDirectory: true)
}

private func watch(_ videoId: String, _ channelId: String) -> HistoryChannelWatch {
    HistoryChannelWatch(videoId: videoId, channelId: channelId, channelTitle: "Channel \(channelId)")
}

@Suite("FrequentChannelHistoryCache")
struct FrequentChannelHistoryCacheTests {

    @Test func emptyCacheIsStale() async {
        let cache = FrequentChannelHistoryCache(directory: nil)
        let snap = await cache.snapshot(ownerKey: "primary")
        #expect(snap.watches.isEmpty)
        #expect(snap.stale)
    }

    @Test func storedWatchesAreFreshWithinTTL() async {
        let clock = TestClock()
        let cache = FrequentChannelHistoryCache(ttl: 15 * 60, directory: nil, now: { clock.now })
        await cache.store([watch("v1", "c1")], ownerKey: "primary")

        clock.now.addTimeInterval(14 * 60)
        let snap = await cache.snapshot(ownerKey: "primary")
        #expect(snap.watches == [watch("v1", "c1")])
        #expect(!snap.stale)
    }

    @Test func storedWatchesGoStaleAfterTTL() async {
        let clock = TestClock()
        let cache = FrequentChannelHistoryCache(ttl: 15 * 60, directory: nil, now: { clock.now })
        await cache.store([watch("v1", "c1")], ownerKey: "primary")

        clock.now.addTimeInterval(15 * 60)
        let snap = await cache.snapshot(ownerKey: "primary")
        // Stale entries are still served (stale-while-revalidate), but flagged.
        #expect(snap.watches == [watch("v1", "c1")])
        #expect(snap.stale)
    }

    @Test func emptyStoreDoesNotWipeGoodCache() async {
        let clock = TestClock()
        let cache = FrequentChannelHistoryCache(directory: nil, now: { clock.now })
        await cache.store([watch("v1", "c1")], ownerKey: "primary")
        await cache.store([], ownerKey: "primary")
        #expect(await cache.snapshot(ownerKey: "primary").watches == [watch("v1", "c1")])
    }

    @Test func accountsAreIsolated() async {
        let cache = FrequentChannelHistoryCache(directory: nil)
        await cache.store([watch("v1", "c1")], ownerKey: "account-a")
        let other = await cache.snapshot(ownerKey: "account-b")
        #expect(other.watches.isEmpty)
        #expect(other.stale)
    }

    @Test func resetClearsMemoryAndDisk() async {
        let dir = tempDirectory()
        let cache = FrequentChannelHistoryCache(directory: dir)
        await cache.store([watch("v1", "c1")], ownerKey: "primary")
        await cache.reset()

        #expect(await cache.snapshot(ownerKey: "primary").watches.isEmpty)
        let reopened = FrequentChannelHistoryCache(directory: dir)
        #expect(await reopened.snapshot(ownerKey: "primary").watches.isEmpty)
    }

    @Test func entriesSurviveRelaunchWithTheirAge() async {
        let dir = tempDirectory()
        let clock = TestClock()
        let first = FrequentChannelHistoryCache(ttl: 15 * 60, directory: dir, now: { clock.now })
        await first.store([watch("v1", "c1"), watch("v2", "c2")], ownerKey: "primary")

        // A new instance (relaunch) reads the persisted file and keeps the original timestamp.
        clock.now.addTimeInterval(5 * 60)
        let relaunched = FrequentChannelHistoryCache(ttl: 15 * 60, directory: dir, now: { clock.now })
        let fresh = await relaunched.snapshot(ownerKey: "primary")
        #expect(fresh.watches.map(\.videoId) == ["v1", "v2"])
        #expect(!fresh.stale)

        clock.now.addTimeInterval(11 * 60)
        let aged = FrequentChannelHistoryCache(ttl: 15 * 60, directory: dir, now: { clock.now })
        #expect(await aged.snapshot(ownerKey: "primary").stale)
    }
}
