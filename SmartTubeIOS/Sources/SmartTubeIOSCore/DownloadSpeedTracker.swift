import Foundation

/// Turns a stream of "total bytes received so far" readings into a smoothed bytes-per-second figure.
/// Pure value type with injected timestamps, so it is deterministic to test.
public struct DownloadSpeedTracker: Sendable, Equatable {
    /// Weight of the newest sample in the moving average (higher reacts faster, lower is steadier).
    public static let smoothing = 0.3
    /// A gap longer than this between readings (a pause, a stall) restarts the measurement.
    public static let staleGap: TimeInterval = 5

    private var lastBytes: Int64?
    private var lastTime: Date?
    public private(set) var bytesPerSecond: Double = 0

    public init() {}

    /// Records `totalBytes` received as of `now` and returns the smoothed speed.
    @discardableResult
    public mutating func record(totalBytes: Int64, at now: Date) -> Double {
        defer {
            lastBytes = totalBytes
            lastTime = now
        }
        guard let lastBytes, let lastTime else { return bytesPerSecond }
        let dt = now.timeIntervalSince(lastTime)
        guard dt > 0 else { return bytesPerSecond }
        if dt > Self.staleGap || totalBytes < lastBytes {
            bytesPerSecond = 0
            return bytesPerSecond
        }
        let instant = Double(totalBytes - lastBytes) / dt
        bytesPerSecond =
            bytesPerSecond == 0 ? instant : Self.smoothing * instant + (1 - Self.smoothing) * bytesPerSecond
        return bytesPerSecond
    }

    /// Forgets all readings (the download was paused or finished).
    public mutating func reset() { self = DownloadSpeedTracker() }
}
