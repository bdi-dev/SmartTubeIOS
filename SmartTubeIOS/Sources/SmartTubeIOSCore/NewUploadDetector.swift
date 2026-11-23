import Foundation

// MARK: - NewUploadDetector
//
// Pure decision: which videos in a freshly fetched feed deserve an alert?

public enum NewUploadDetector {
    /// Most alerts raised by a single check; more than this would just be noise.
    public static let maxAlertsPerCheck = 5

    public struct Result: Equatable, Sendable {
        /// Videos to announce (newest first as supplied, capped).
        public let toNotify: [Video]
        /// Every id in the feed, to mark as seen whether or not it was announced.
        public let allIds: [String]
        public static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.toNotify.map(\.id) == rhs.toNotify.map(\.id) && lhs.allIds == rhs.allIds
        }
    }

    /// - Parameters:
    ///   - feed: freshly fetched uploads, newest first.
    ///   - seenIds: ids already recorded.
    ///   - hasBaseline: `false` on the first ever check — then nothing is announced.
    ///   - isMuted: channels the user has blocked / excluded; never announced.
    public static func evaluate(
        feed: [Video], seenIds: Set<String>, hasBaseline: Bool, isMuted: (Video) -> Bool = { _ in false },
        limit: Int = maxAlertsPerCheck
    ) -> Result {
        let allIds = feed.map(\.id).filter { !$0.isEmpty }
        guard hasBaseline else { return Result(toNotify: [], allIds: allIds) }
        var announced = Set<String>()
        var out: [Video] = []
        for video in feed {
            guard out.count < limit else { break }
            guard !video.id.isEmpty, !seenIds.contains(video.id), !announced.contains(video.id) else { continue }
            guard !video.isLive, !isMuted(video) else { continue }
            announced.insert(video.id)
            out.append(video)
        }
        return Result(toNotify: out, allIds: allIds)
    }
}
