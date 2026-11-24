import Foundation
import Testing

@testable import SmartTubeIOSCore

@Suite("DownloadSpeedTracker")
struct DownloadSpeedTrackerTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    @Test("the first reading has no speed; later readings give bytes per second")
    func basicSpeed() {
        var tracker = DownloadSpeedTracker()
        #expect(tracker.record(totalBytes: 0, at: t0) == 0)
        #expect(tracker.record(totalBytes: 2_000_000, at: t0.addingTimeInterval(1)) == 2_000_000)
    }

    @Test("speed is smoothed between readings")
    func smoothing() {
        var tracker = DownloadSpeedTracker()
        tracker.record(totalBytes: 0, at: t0)
        tracker.record(totalBytes: 1_000_000, at: t0.addingTimeInterval(1))  // 1 MB/s
        let speed = tracker.record(totalBytes: 3_000_000, at: t0.addingTimeInterval(2))  // instant 2 MB/s
        #expect(speed > 1_000_000 && speed < 2_000_000)
    }

    @Test("a long gap or a reset restarts the measurement")
    func staleAndReset() {
        var tracker = DownloadSpeedTracker()
        tracker.record(totalBytes: 0, at: t0)
        tracker.record(totalBytes: 1_000_000, at: t0.addingTimeInterval(1))
        #expect(tracker.record(totalBytes: 2_000_000, at: t0.addingTimeInterval(60)) == 0)
        tracker.reset()
        #expect(tracker.bytesPerSecond == 0)
    }
}
