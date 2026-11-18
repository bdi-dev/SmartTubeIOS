import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - LockupWatchProgressTests
//
// "Watched videos don't show as played in the channel view": the WEB channel Videos tab
// returns `lockupViewModel` (confirmed by a live signed-out capture), whose resume
// progress lives in the thumbnail view-model overlays, a path the parser used to ignore.
//
// Fixture provenance:
//  - `signedOutOverlays` mirrors a REAL signed-out capture (badges + hover toggles, no
//    progress bar), trimmed.
//  - The progress-bar shapes are SHAPE-BASED (from public InnerTube client references),
//    because a populated percent cannot be captured signed out.

@Suite("lockupViewModel resume progress")
struct LockupWatchProgressTests {

    private let api = InnerTubeAPI()

    private func lockup(videoId: String, overlays: [[String: Any]]) -> [String: Any] {
        [
            "lockupViewModel": [
                "contentId": videoId,
                "contentImage": [
                    "thumbnailViewModel": [
                        "image": ["sources": [["url": "https://i.ytimg.com/vi/\(videoId)/hq.jpg"]]],
                        "overlays": overlays,
                    ]
                ],
                "metadata": [
                    "lockupMetadataViewModel": ["title": ["content": "T \(videoId)"]]
                ],
                "rendererContext": [
                    "commandContext": [
                        "onTap": ["innertubeCommand": ["watchEndpoint": ["videoId": videoId]]]
                    ]
                ],
            ]
        ]
    }

    // REAL (trimmed) signed-out shape.
    private let signedOutOverlays: [[String: Any]] = [
        [
            "thumbnailBottomOverlayViewModel": [
                "badges": [["thumbnailBadgeViewModel": ["text": "14:19"]]]
            ]
        ],
        ["thumbnailHoverOverlayToggleActionsViewModel": ["buttons": []]],
    ]

    // SHAPE-BASED: progress bar nested in the bottom overlay.
    private func nested(_ pct: Any) -> [[String: Any]] {
        [
            [
                "thumbnailBottomOverlayViewModel": [
                    "progressBar": ["thumbnailOverlayProgressBarViewModel": ["startPercent": pct]],
                    "badges": [["thumbnailBadgeViewModel": ["text": "14:19"]]],
                ]
            ]
        ]
    }

    private func parse(_ items: [[String: Any]]) async throws -> [Video] {
        try await api.parseVideoGroupForTesting(["items": items], title: nil).videos
    }

    @Test("signed-out lockup has no progress")
    func signedOut() async throws {
        let v = try await parse([lockup(videoId: "A", overlays: signedOutOverlays)])
        #expect(v.first?.watchProgress == nil)
    }

    @Test("nested bottom-overlay progress bar maps 0-100 to 0-1")
    func nestedBar() async throws {
        let v = try await parse([
            lockup(videoId: "A", overlays: nested(45)),
            lockup(videoId: "B", overlays: nested(100)),
            lockup(videoId: "C", overlays: nested(12.5)),
        ])
        #expect(v.map(\.watchProgress) == [0.45, 1.0, 0.125])
    }

    @Test("progress bar directly under overlays is read")
    func directBar() async throws {
        let v = try await parse([
            lockup(videoId: "A", overlays: [["thumbnailOverlayProgressBarViewModel": ["startPercent": 80]]])
        ])
        #expect(v.first?.watchProgress == 0.8)
    }

    @Test("zero and out-of-range values")
    func clamps() async throws {
        let v = try await parse([
            lockup(videoId: "A", overlays: nested(0)),
            lockup(videoId: "B", overlays: nested(250)),
        ])
        #expect(v[0].watchProgress == nil)
        #expect(v[1].watchProgress == 1.0)
    }

    @Test("richItemRenderer-wrapped lockup keeps progress")
    func richItem() async throws {
        let inner = lockup(videoId: "A", overlays: nested(60))
        let v = try await parse([["richItemRenderer": ["content": inner]]])
        #expect(v.first?.watchProgress == 0.6)
    }
}

@Suite("WatchedHistoryIndex fallback")
struct WatchedHistoryIndexTests {

    @Test("merge fills only videos without their own progress")
    func merge() {
        let a = Video(id: "A", title: "a", channelTitle: "c")
        var b = Video(id: "B", title: "b", channelTitle: "c")
        b.watchProgress = 0.3
        let c = Video(id: "C", title: "c", channelTitle: "c")
        let out = WatchedHistoryIndex.merge([a, b, c], index: ["A": 1.0, "B": 1.0])
        #expect(out[0].watchProgress == 1.0)
        #expect(out[1].watchProgress == 0.3)
        #expect(out[2].watchProgress == nil)
    }

    @Test("index is cached within TTL, reloaded after, and isolated per account")
    func caching() async {
        let box = LockedBox()
        let idx = WatchedHistoryIndex(ttl: 100, maxEntries: 10, now: { box.date })
        let loader: @Sendable () async throws -> [String: Double] = {
            box.loads += 1
            return ["X": 1.0]
        }
        _ = await idx.index(ownerKey: "u1", load: loader)
        _ = await idx.index(ownerKey: "u1", load: loader)
        #expect(box.loads == 1)
        box.date = Date(timeIntervalSince1970: 200)
        _ = await idx.index(ownerKey: "u1", load: loader)
        #expect(box.loads == 2)
        _ = await idx.index(ownerKey: "u2", load: loader)
        #expect(box.loads == 3)
    }

    @Test("failed load is not cached")
    func failure() async {
        let box = LockedBox()
        let idx = WatchedHistoryIndex(ttl: 100, maxEntries: 10, now: { box.date })
        struct E: Error {}
        let r = await idx.index(ownerKey: "u") { box.loads += 1; throw E() }
        #expect(r.isEmpty)
        _ = await idx.index(ownerKey: "u") { box.loads += 1; throw E() }
        #expect(box.loads == 2)
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _date = Date(timeIntervalSince1970: 0)
    private var _loads = 0
    var date: Date { get { lock.withLock { _date } } set { lock.withLock { _date = newValue } } }
    var loads: Int { get { lock.withLock { _loads } } set { lock.withLock { _loads = newValue } } }
}
