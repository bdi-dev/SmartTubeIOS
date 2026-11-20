import Foundation

// MARK: - HideWatchedFilter (#121, plan 11)
//
// The one definition of "watched" for the Hide Watched Videos filters. It uses the same
// combined signal the cards display (`WatchProgressPolicy.combined`): the progress that
// came with the first load, the account's YouTube History index, and local playback.
// Before this, the filters read only the first-load progress, so a video that showed as
// watched on its card could stay in a "hide watched" list.

/// Progress signals read from the stores, keyed by video id. Filters take a snapshot so
/// they stay synchronous; views refresh it when the stores change.
public struct WatchProgressSnapshot: Sendable, Equatable {
    /// YouTube History index progress (0...1).
    public var history: [String: Double]
    /// Local playback fraction (0...1), from `VideoStateStore`.
    public var local: [String: Double]

    public static let empty = WatchProgressSnapshot(history: [:], local: [:])

    public init(history: [String: Double], local: [String: Double]) {
        self.history = history
        self.local = local
    }

    /// Reads the current History index and local playback states.
    public static func current() async -> WatchProgressSnapshot {
        async let history = WatchedHistoryIndex.shared.allProgress()
        async let local = VideoStateStore.shared.allWatchedFractions()
        return await WatchProgressSnapshot(history: history, local: local)
    }

    /// The progress the card shows for `video`: the largest signal available, or nil.
    public func progress(for video: Video) -> Double? {
        WatchProgressPolicy.combined(video.watchProgress, history[video.id], local[video.id])
    }
}

public enum HideWatchedFilter {
    /// True when the combined progress is at or past `threshold` (inclusive, as before #121).
    /// No signal at all is never watched.
    public static func isWatched(_ video: Video, threshold: Double, in snapshot: WatchProgressSnapshot) -> Bool {
        guard let progress = snapshot.progress(for: video) else { return false }
        return progress >= threshold
    }

    /// `videos` without the watched ones. Ids in `keeping` stay even when watched, so a
    /// card the user has just played does not disappear under them.
    public static func removingWatched(
        _ videos: [Video],
        threshold: Double,
        in snapshot: WatchProgressSnapshot,
        keeping: Set<String> = []
    ) -> [Video] {
        videos.filter { keeping.contains($0.id) || !isWatched($0, threshold: threshold, in: snapshot) }
    }
}
