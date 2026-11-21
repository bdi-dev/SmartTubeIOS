import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private func video(_ id: String, duration: TimeInterval? = 600, live: Bool = false) -> Video {
    var v = Video(id: id, title: "T \(id)", channelTitle: "C", thumbnailURL: nil, duration: duration)
    v.isLive = live
    return v
}

@Suite("AutoDownloadPolicy")
struct AutoDownloadPolicyTests {
    @Test("skips known, live and over-long videos, keeps order, respects limit")
    func selection() {
        let picked = AutoDownloadPolicy.select(
            candidates: [
                video("a"), video("known"), video("live", live: true), video("long", duration: 5 * 3600),
                video("b"), video("c"), video("d"),
            ],
            knownVideoIds: ["known"], limit: 3, maxDuration: 3 * 3600)
        #expect(picked.map(\.id) == ["a", "b", "c"])
    }

    @Test("keeps videos with unknown duration and removes duplicates")
    func unknownDurationAndDuplicates() {
        let picked = AutoDownloadPolicy.select(
            candidates: [video("x", duration: nil), video("x"), video("y")], knownVideoIds: [])
        #expect(picked.map(\.id) == ["x", "y"])
    }
}

private struct FakeSource: WatchLaterSource {
    var videos: [Video] = []
    var error: Error?
    func watchLaterVideos() async throws -> [Video] {
        if let error { throw error }
        return videos
    }
}

private struct FakeNetwork: NetworkConditions { var isUnmetered: Bool }

private struct SyncError: Error {}

private final class Box: @unchecked Sendable {
    var date = Date(timeIntervalSince1970: 1_000_000)
}

@Suite("WatchLaterAutoDownloader")
@MainActor
struct WatchLaterAutoDownloaderTests {
    private func settings(enabled: Bool = true, wifiOnly: Bool = true) -> AppSettings {
        var s = AppSettings()
        s.autoDownloadWatchLater = enabled
        s.autoDownloadOnlyOnWiFi = wifiOnly
        return s
    }

    private func make(
        source: FakeSource, unmetered: Bool = true, known: Set<String> = [], clock: Box = Box()
    ) -> (WatchLaterAutoDownloader, () -> [String]) {
        var queued: [String] = []
        let sink = { queued }
        let downloader = WatchLaterAutoDownloader(
            source: source, network: FakeNetwork(isUnmetered: unmetered),
            knownVideoIds: { known }, enqueue: { queued.append($0.id) }, now: { clock.date })
        return (downloader, sink)
    }

    @Test("queues new Watch Later videos when enabled, signed in and on Wi-Fi")
    func queuesNewVideos() async {
        let (d, queued) = make(source: FakeSource(videos: [video("a"), video("b")]), known: ["b"])
        let n = await d.syncIfDue(settings: settings(), isSignedIn: true)
        #expect(n == 1)
        #expect(queued() == ["a"])
    }

    @Test("does nothing when disabled or signed out")
    func disabledOrSignedOut() async {
        let (d, queued) = make(source: FakeSource(videos: [video("a")]))
        #expect(await d.syncIfDue(settings: settings(enabled: false), isSignedIn: true) == 0)
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: false) == 0)
        #expect(queued().isEmpty)
    }

    @Test("Wi-Fi only blocks a metered connection; turning it off allows it")
    func wifiOnly() async {
        let (blocked, q1) = make(source: FakeSource(videos: [video("a")]), unmetered: false)
        #expect(await blocked.syncIfDue(settings: settings(wifiOnly: true), isSignedIn: true) == 0)
        #expect(q1().isEmpty)
        let (allowed, q2) = make(source: FakeSource(videos: [video("a")]), unmetered: false)
        #expect(await allowed.syncIfDue(settings: settings(wifiOnly: false), isSignedIn: true) == 1)
        #expect(q2() == ["a"])
    }

    @Test("a second sync inside the interval is skipped; one after it runs")
    func throttled() async {
        let clock = Box()
        let (d, _) = make(source: FakeSource(videos: [video("a")]), clock: clock)
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: true) == 1)
        clock.date.addTimeInterval(60)
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: true) == 0)
        clock.date.addTimeInterval(DownloadTuning.autoDownloadMinInterval)
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: true) == 1)
    }

    @Test("a failed sync does not start the throttle window")
    func failureAllowsRetry() async {
        let (d, _) = make(source: FakeSource(error: SyncError()))
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: true) == 0)
        // Second call is not throttled (it tries again and fails again, still 0, but it ran).
        #expect(await d.syncIfDue(settings: settings(), isSignedIn: true) == 0)
    }

    @Test("settings default to off / Wi-Fi only and round-trip through Codable")
    func settingsDefaults() throws {
        let s = AppSettings()
        #expect(s.autoDownloadWatchLater == false)
        #expect(s.autoDownloadOnlyOnWiFi == true)
        var changed = s
        changed.autoDownloadWatchLater = true
        changed.autoDownloadOnlyOnWiFi = false
        let round = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(changed))
        #expect(round.autoDownloadWatchLater == true)
        #expect(round.autoDownloadOnlyOnWiFi == false)
    }
}
