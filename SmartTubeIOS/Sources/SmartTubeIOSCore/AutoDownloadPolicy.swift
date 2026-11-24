import Foundation

// MARK: - AutoDownloadPolicy
//
// Pure selection rule for automatic downloads (e.g. Watch Later). Deliberately has no side
// effects and never removes anything: it only says which videos are worth queuing.

public enum AutoDownloadPolicy {
    /// Picks the videos to queue from `candidates`, in order.
    /// - Skips anything already known to the library (any status, so a failed video is not
    ///   retried in a loop; the user can retry it by hand).
    /// - Skips live streams and videos longer than `maxDuration`.
    /// - Keeps unknown-duration videos (the feed does not always report one).
    /// - Returns at most `limit` videos.
    public static func select(
        candidates: [Video],
        knownVideoIds: Set<String>,
        limit: Int = DownloadTuning.autoDownloadMaxPerSync,
        maxDuration: TimeInterval = DownloadTuning.autoDownloadMaxDuration
    ) -> [Video] {
        var seen = knownVideoIds
        var picked: [Video] = []
        for video in candidates {
            guard picked.count < limit else { break }
            guard !video.id.isEmpty, !seen.contains(video.id) else { continue }
            guard !video.isLive else { continue }
            if let duration = video.duration, duration > maxDuration { continue }
            seen.insert(video.id)
            picked.append(video)
        }
        return picked
    }
}
