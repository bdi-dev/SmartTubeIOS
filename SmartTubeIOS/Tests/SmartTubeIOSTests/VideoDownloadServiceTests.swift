import Foundation
import Testing
import os

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

// MARK: - Fake fetcher

/// Deterministic `DownloadFetching` fake. Each video follows a `Plan`; `.hold` suspends the fetch
/// until the test calls `release(_:)`, which lets tests observe concurrency without sleeping.
private final class FakeFetcher: DownloadFetching, @unchecked Sendable {
    enum Plan {
        case succeed
        case fail(String)
        case hold
    }

    private struct State {
        var plans: [String: Plan] = [:]
        var started: [String] = []
        var inFlight = 0
        var maxInFlight = 0
        var gates: [String: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPlan(_ plan: Plan, for id: String) {
        state.withLock { $0.plans[id] = plan }
    }

    var started: [String] { state.withLock { $0.started } }
    var maxInFlight: Int { state.withLock { $0.maxInFlight } }

    func release(_ id: String) {
        let gate = state.withLock { $0.gates.removeValue(forKey: id) }
        gate?.resume()
    }

    func fetch(video: Video, onEvent: @escaping @Sendable (DownloadFetchEvent) -> Void) async throws -> URL {
        let plan = state.withLock { s -> Plan in
            s.started.append(video.id)
            s.inFlight += 1
            s.maxInFlight = max(s.maxInFlight, s.inFlight)
            return s.plans[video.id] ?? .succeed
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        switch plan {
        case .fail(let message):
            throw DownloadFetchError(message: message)
        case .hold:
            await withCheckedContinuation { cont in
                state.withLock { $0.gates[video.id] = cont }
            }
        case .succeed:
            break
        }
        onEvent(.progress(1))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mp4")
        try Data("video-\(video.id)".utf8).write(to: url)
        return url
    }
}

// MARK: - Helpers

@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<20_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

private func makeVideo(_ id: String) -> Video {
    Video(id: id, title: "Title \(id)", channelTitle: "Chan", thumbnailURL: nil, duration: 60)
}

@MainActor
private func makeService(
    fetcher: FakeFetcher, maxConcurrent: Int = DownloadTuning.maxConcurrent
) -> (VideoDownloadService, DownloadStore) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("VideoDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
    let store = DownloadStore(directory: dir)
    let service = VideoDownloadService(
        store: store, fetcher: fetcher, maxConcurrent: maxConcurrent, liveActivitiesEnabled: false)
    return (service, store)
}

// MARK: - Tests

@Suite("VideoDownloadService queue")
@MainActor
struct VideoDownloadServiceTests {

    @Test("A successful fetch ends complete with the file in the downloads directory")
    func successCompletes() async throws {
        let fetcher = FakeFetcher()
        let (service, store) = makeService(fetcher: fetcher)
        service.enqueue(video: makeVideo("ok1"))
        #expect(await waitUntil { store.entry(for: "ok1")?.status == .complete })
        let entry = try #require(store.entry(for: "ok1"))
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: entry).path))
        #expect(entry.progress == 1)
    }

    @Test("A failing fetch ends failed with the error message")
    func failureMarksFailed() async {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.fail("boom"), for: "bad1")
        let (service, store) = makeService(fetcher: fetcher)
        service.enqueue(video: makeVideo("bad1"))
        #expect(await waitUntil { store.entry(for: "bad1")?.status == .failed })
        #expect(store.entry(for: "bad1")?.errorMessage == "boom")
        #expect(store.video(for: store.entry(for: "bad1")!) == nil)
    }

    @Test("Enqueueing the same video twice fetches it once")
    func duplicateEnqueueIgnored() async {
        let fetcher = FakeFetcher()
        let (service, store) = makeService(fetcher: fetcher)
        service.enqueue(video: makeVideo("dup"))
        service.enqueue(video: makeVideo("dup"))
        #expect(await waitUntil { store.entry(for: "dup")?.status == .complete })
        // Enqueue again after completion: still ignored.
        service.enqueue(video: makeVideo("dup"))
        await Task.yield()
        #expect(fetcher.started == ["dup"])
        #expect(store.entries.count == 1)
    }

    @Test("At most maxConcurrent run at once and items start in FIFO order")
    func concurrencyAndOrdering() async {
        let fetcher = FakeFetcher()
        for id in ["a", "b", "c", "d"] { fetcher.setPlan(.hold, for: id) }
        let (service, store) = makeService(fetcher: fetcher, maxConcurrent: 2)
        for id in ["a", "b", "c", "d"] { service.enqueue(video: makeVideo(id)) }

        #expect(await waitUntil { fetcher.started.count == 2 })
        #expect(fetcher.started == ["a", "b"])
        #expect(store.entry(for: "c")?.status == .queued)
        #expect(store.entry(for: "d")?.status == .queued)

        fetcher.release("a")
        #expect(await waitUntil { fetcher.started.count == 3 })
        #expect(fetcher.started == ["a", "b", "c"])
        #expect(await waitUntil { store.entry(for: "a")?.status == .complete })

        fetcher.release("b")
        #expect(await waitUntil { fetcher.started.count == 4 })
        fetcher.release("c")
        fetcher.release("d")
        #expect(
            await waitUntil { ["a", "b", "c", "d"].allSatisfy { store.entry(for: $0)?.status == .complete } })
        #expect(fetcher.started == ["a", "b", "c", "d"])
        #expect(fetcher.maxInFlight == 2)
    }

    @Test("Retry re-queues a failed download and can then succeed")
    func retryAfterFailure() async {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.fail("nope"), for: "r1")
        let (service, store) = makeService(fetcher: fetcher)
        service.enqueue(video: makeVideo("r1"))
        #expect(await waitUntil { store.entry(for: "r1")?.status == .failed })

        fetcher.setPlan(.succeed, for: "r1")
        service.retry(videoId: "r1")
        #expect(await waitUntil { store.entry(for: "r1")?.status == .complete })
        #expect(fetcher.started == ["r1", "r1"])
    }

    @Test("Cancelling a queued item removes it from the queue without fetching")
    func cancelQueued() async {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.hold, for: "x")
        let (service, store) = makeService(fetcher: fetcher, maxConcurrent: 1)
        service.enqueue(video: makeVideo("x"))
        service.enqueue(video: makeVideo("y"))
        #expect(await waitUntil { fetcher.started == ["x"] })
        service.cancel(videoId: "y")
        #expect(store.entry(for: "y")?.status == .failed)
        fetcher.release("x")
        #expect(await waitUntil { store.entry(for: "x")?.status == .complete })
        #expect(fetcher.started == ["x"])
    }
}
