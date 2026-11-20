import Foundation
import Testing

@testable import InnerTubeKit
@testable import SmartTubeIOSCore

// MARK: - HideWatchedFilter (#121, plan 11)
//
// The filters must use the same combined progress the cards show, not only the progress
// that came with the first load.

@Suite("HideWatchedFilter (plan 11)")
struct HideWatchedFilterTests {

    private func video(_ id: String, progress: Double? = nil) -> Video {
        Video(id: id, title: id, channelTitle: "channel", watchProgress: progress)
    }

    @Test("first-load progress alone hides a video")
    func firstLoadProgress() {
        let snapshot = WatchProgressSnapshot.empty
        #expect(HideWatchedFilter.isWatched(video("a", progress: 0.95), threshold: 0.9, in: snapshot))
    }

    @Test("History-index progress hides a video whose response carried none")
    func indexOnlyProgress() {
        let snapshot = WatchProgressSnapshot(history: ["a": 1.0], local: [:])
        #expect(HideWatchedFilter.isWatched(video("a"), threshold: 0.9, in: snapshot))
    }

    @Test("local playback progress hides a video")
    func localOnlyProgress() {
        let snapshot = WatchProgressSnapshot(history: [:], local: ["a": 0.97])
        #expect(HideWatchedFilter.isWatched(video("a"), threshold: 0.9, in: snapshot))
    }

    @Test("local partial watch does not hide when below threshold")
    func localBelowThreshold() {
        let snapshot = WatchProgressSnapshot(history: [:], local: ["a": 0.2])
        #expect(!HideWatchedFilter.isWatched(video("a"), threshold: 0.9, in: snapshot))
    }

    @Test("largest signal wins across first-load, index and local")
    func largestSignalWins() {
        let snapshot = WatchProgressSnapshot(history: ["a": 0.3], local: ["a": 0.8])
        #expect(snapshot.progress(for: video("a", progress: 0.5)) == 0.8)
        #expect(!HideWatchedFilter.isWatched(video("a", progress: 0.5), threshold: 0.9, in: snapshot))
    }

    @Test("threshold boundary is inclusive")
    func thresholdBoundary() {
        let snapshot = WatchProgressSnapshot(history: [:], local: ["a": 0.9])
        #expect(HideWatchedFilter.isWatched(video("a"), threshold: 0.9, in: snapshot))
        #expect(!HideWatchedFilter.isWatched(video("a"), threshold: 0.91, in: snapshot))
    }

    @Test("no signal anywhere is never watched")
    func nilEverywhere() {
        let snapshot = WatchProgressSnapshot.empty
        #expect(snapshot.progress(for: video("a")) == nil)
        #expect(!HideWatchedFilter.isWatched(video("a"), threshold: 0.5, in: snapshot))
    }

    @Test("removingWatched keeps order and drops only watched videos")
    func removingWatchedFilters() {
        let snapshot = WatchProgressSnapshot(history: ["b": 1.0], local: ["d": 0.95])
        let videos = [video("a", progress: 0.1), video("b"), video("c"), video("d")]
        let kept = HideWatchedFilter.removingWatched(videos, threshold: 0.9, in: snapshot)
        #expect(kept.map(\.id) == ["a", "c"])
    }

    @Test("keeping protects a watched video from removal")
    func keepingProtectsPlayed() {
        let snapshot = WatchProgressSnapshot(history: ["b": 1.0], local: [:])
        let videos = [video("a"), video("b")]
        let kept = HideWatchedFilter.removingWatched(
            videos, threshold: 0.9, in: snapshot, keeping: ["b"])
        #expect(kept.map(\.id) == ["a", "b"])
    }

    @Test("empty input stays empty")
    func emptyInput() {
        let kept = HideWatchedFilter.removingWatched([], threshold: 0.9, in: .empty)
        #expect(kept.isEmpty)
    }
}
