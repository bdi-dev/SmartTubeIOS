#if os(iOS)
import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

private func video(_ id: String, channel: String = "c1") -> Video {
    var v = Video(id: id, title: "T \(id)", channelTitle: "Chan", thumbnailURL: nil, duration: 100)
    v.channelId = channel
    return v
}

private struct FakeFeed: UploadFeedSource {
    var videos: [Video]
    func latestUploads() async -> [Video] { videos }
}

private final class FakePoster: UploadNotificationPosting, @unchecked Sendable {
    var authorized: Bool
    var posted: [String] = []
    init(authorized: Bool = true) { self.authorized = authorized }
    func requestAuthorization() async -> Bool {
        authorized = true
        return true
    }
    func isAuthorized() async -> Bool { authorized }
    func post(_ video: Video) async { posted.append(video.id) }
}

private final class Clock: @unchecked Sendable { var date = Date(timeIntervalSince1970: 5_000_000) }

@Suite("NewUploadNotifier")
@MainActor
struct NewUploadNotifierTests {
    private func settings(on: Bool = true, blocked: [String: String] = [:]) -> AppSettings {
        var s = AppSettings()
        s.notifyNewUploads = on
        s.blockedChannels = blocked
        return s
    }

    private func make(
        feed: [Video], poster: FakePoster = FakePoster(), clock: Clock = Clock()
    ) -> (NewUploadNotifier, FakePoster, SeenUploadsStore) {
        let seen = SeenUploadsStore(suiteName: "test-\(UUID().uuidString)")
        let notifier = NewUploadNotifier(
            source: FakeFeed(videos: feed), poster: poster, seen: seen, now: { clock.date })
        return (notifier, poster, seen)
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
        let (off, p1, _) = make(feed: [video("a")])
        #expect(await off.checkIfDue(settings: settings(on: false)) == 0)
        #expect(p1.posted.isEmpty)
        let (denied, p2, seen) = make(feed: [video("a")], poster: FakePoster(authorized: false))
        #expect(await denied.checkIfDue(settings: settings()) == 0)
        #expect(p2.posted.isEmpty)
        #expect(await seen.hasBaseline == false)
    }

    @Test("checks are throttled; force bypasses the throttle")
    func throttled() async {
        let (n, _, _) = make(feed: [video("a")])
        _ = await n.checkIfDue(settings: settings())
        #expect(await n.checkIfDue(settings: settings()) == 0)
        _ = await n.checkIfDue(settings: settings(), force: true)
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

    @Test("enable() requests authorisation when needed")
    func enableRequests() async {
        let (n, poster, _) = make(feed: [], poster: FakePoster(authorized: false))
        #expect(await n.enable())
        #expect(poster.authorized)
    }
}

private final class FeedBox: @unchecked Sendable {
    var videos: [Video]
    init(_ videos: [Video]) { self.videos = videos }
}

private struct FakeFeedBox: UploadFeedSource {
    let box: FeedBox
    init(_ box: FeedBox) { self.box = box }
    func latestUploads() async -> [Video] { box.videos }
}
#endif
