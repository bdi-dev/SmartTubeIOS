#if os(iOS)
import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private func video(_ id: String, channel: String = "c1") -> Video {
    var result = Video(id: id, title: "T \(id)", channelTitle: "Chan", thumbnailURL: nil, duration: 100)
    result.channelId = channel
    return result
}

private struct FakeFeed: UploadFeedSource {
    var videos: [Video]
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func latestUploads() async -> [Video] { videos }
}

private final class FakePoster: UploadNotificationPosting, @unchecked Sendable {
    var authorized: Bool
    var posted: [String] = []
    init(authorized: Bool = true) { self.authorized = authorized }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func requestAuthorization() async -> Bool {
        authorized = true
        return true
    }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func isAuthorized() async -> Bool { authorized }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func post(_ video: Video) async { posted.append(video.id) }
}

private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 5_000_000) }

private struct Harness {
    let notifier: NewUploadNotifier
    let poster: FakePoster
    let seen: SeenUploadsStore
}

@Suite("NewUploadNotifier")
@MainActor
struct NewUploadNotifierTests {
    private func settings(on: Bool = true, blocked: [String: String] = [:]) -> AppSettings {
        var appSettings = AppSettings()
        appSettings.notifyNewUploads = on
        appSettings.blockedChannels = blocked
        return appSettings
    }

    private func make(
        feed: [Video], poster: FakePoster = FakePoster(), clock: Clock = Clock()
    ) -> Harness {
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        let notifier = NewUploadNotifier(
            source: FakeFeed(videos: feed), poster: poster, seen: seen, now: { clock.date })
        return Harness(notifier: notifier, poster: poster, seen: seen)
    }

    @Test("the first check is silent; later new uploads are announced")
    func baselineThenAnnounce() async {
        let clock = Clock()
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        let poster = FakePoster()
        let feed = FeedBox([video("a"), video("b")])
        let notifier = NewUploadNotifier(
            source: FakeFeedBox(feed), poster: poster, seen: seen, now: { clock.date })
        #expect(await notifier.checkIfDue(settings: settings()) == 0)
        #expect(poster.posted.isEmpty)

        feed.videos = [video("new"), video("a"), video("b")]
        clock.date.addTimeInterval(NewUploadNotifier.minInterval + 1)
        #expect(await notifier.checkIfDue(settings: settings()) == 1)
        #expect(poster.posted == ["new"])
    }

    @Test("does nothing when disabled or not authorised")
    func disabledOrUnauthorised() async {
        let off = make(feed: [video("a")])
        #expect(await off.notifier.checkIfDue(settings: settings(on: false)) == 0)
        #expect(off.poster.posted.isEmpty)
        let denied = make(feed: [video("a")], poster: FakePoster(authorized: false))
        #expect(await denied.notifier.checkIfDue(settings: settings()) == 0)
        #expect(denied.poster.posted.isEmpty)
        #expect(await denied.seen.hasBaseline() == false)
    }

    @Test("checks are throttled; force bypasses the throttle")
    func throttled() async {
        let harness = make(feed: [video("a")])
        _ = await harness.notifier.checkIfDue(settings: settings())
        #expect(await harness.notifier.checkIfDue(settings: settings()) == 0)
        _ = await harness.notifier.checkIfDue(settings: settings(), force: true)
    }

    @Test("blocked channels are never announced")
    func blockedChannelsSkipped() async {
        let clock = Clock()
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        await seen.markSeen(["old"])
        let poster = FakePoster()
        let notifier = NewUploadNotifier(
            source: FakeFeed(videos: [video("x", channel: "bad"), video("y")]), poster: poster, seen: seen,
            now: { clock.date })
        #expect(await notifier.checkIfDue(settings: settings(blocked: ["bad": "Bad"])) == 1)
        #expect(poster.posted == ["y"])
    }

    @Test("signing in later records a separate baseline instead of flooding alerts")
    func signedInBaselineIsSeparate() async {
        let clock = Clock()
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        let poster = FakePoster()
        let local = FeedBox([video("l1")])
        let subs = FeedBox([])  // signed out: empty
        let notifier = NewUploadNotifier(
            sources: [("local", FakeFeedBox(local)), ("subscriptions", FakeFeedBox(subs))],
            poster: poster, seen: seen, now: { clock.date })
        #expect(await notifier.checkIfDue(settings: settings()) == 0)  // local baseline only

        subs.videos = [video("s1", channel: "c9"), video("s2", channel: "c9")]  // user signs in
        clock.date.addTimeInterval(NewUploadNotifier.minInterval + 1)
        #expect(await notifier.checkIfDue(settings: settings()) == 0)  // subscriptions baseline, silent
        #expect(poster.posted.isEmpty)

        subs.videos = [video("s3", channel: "c9")] + subs.videos
        clock.date.addTimeInterval(NewUploadNotifier.minInterval + 1)
        #expect(await notifier.checkIfDue(settings: settings()) == 1)
        #expect(poster.posted == ["s3"])
    }

    @Test("switching account takes a new silent baseline instead of announcing its existing uploads")
    func accountSwitchIsSilent() async {
        let clock = Clock()
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        let poster = FakePoster()
        let feed = FeedBox([video("a1")])
        let scope = ScopeBox("primary")
        let notifier = NewUploadNotifier(
            sources: [(SeenUploadsStore.subscriptionsSource, ScopedFeed(box: feed, scope: scope))],
            poster: poster, seen: seen, now: { clock.date })
        #expect(await notifier.checkIfDue(settings: settings()) == 0)  // primary baseline

        scope.value = "brand-1"  // user switches to a Brand Account with its own existing uploads
        feed.videos = [video("b1"), video("b2")]
        clock.date.addTimeInterval(NewUploadNotifier.minInterval + 1)
        #expect(await notifier.checkIfDue(settings: settings()) == 0)
        #expect(poster.posted.isEmpty)

        feed.videos = [video("b3")] + feed.videos  // a genuinely new upload is still announced
        clock.date.addTimeInterval(NewUploadNotifier.minInterval + 1)
        #expect(await notifier.checkIfDue(settings: settings()) == 1)
        #expect(poster.posted == ["b3"])
    }

    @Test("a video present in both feeds is announced once, and the total is capped")
    func dedupedAndCapped() async {
        let clock = Clock()
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        await seen.markSeen(["old"], source: "local")
        await seen.markSeen(["old"], source: "subscriptions")
        let poster = FakePoster()
        let both = [video("dup")]
        let many = (0..<8).map { video("m\($0)") }
        let notifier = NewUploadNotifier(
            sources: [
                ("local", FakeFeed(videos: both)), ("subscriptions", FakeFeed(videos: both + many)),
            ], poster: poster, seen: seen, now: { clock.date })
        #expect(await notifier.checkIfDue(settings: settings()) == NewUploadDetector.maxAlertsPerCheck)
        #expect(poster.posted.filter { $0 == "dup" }.count == 1)
        #expect(poster.posted.count == NewUploadDetector.maxAlertsPerCheck)
    }

    @Test("enable() requests authorisation when needed")
    func enableRequests() async {
        let harness = make(feed: [], poster: FakePoster(authorized: false))
        #expect(await harness.notifier.enable())
        #expect(harness.poster.authorized)
    }
}

private final class FeedBox: @unchecked Sendable {
    var videos: [Video]
    init(_ videos: [Video]) { self.videos = videos }
}

private final class ScopeBox: @unchecked Sendable {
    var value: String
    init(_ value: String) { self.value = value }
}

private struct ScopedFeed: UploadFeedSource {
    let box: FeedBox
    let scope: ScopeBox
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func latestUploads() async -> [Video] { box.videos }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func baselineScope() async -> String? { scope.value }
}

private struct FakeFeedBox: UploadFeedSource {
    let box: FeedBox
    init(_ box: FeedBox) { self.box = box }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func latestUploads() async -> [Video] { box.videos }
}
#endif
