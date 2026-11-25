import Foundation

extension PlaybackViewModel {
    /// Drops the state that would make the next `load(video:)` for the video that is already
    /// current a no-op: an in-flight load of it (ignored as a duplicate) and a parked player item
    /// (reused instead of loading). Call before loading a different stream for the same video id.
    func discardCurrentLoad() {
        loadTask?.cancel()
        isLoading = false
        parkedVideoId = nil
    }
}
