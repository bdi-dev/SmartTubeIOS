import Foundation
import Testing
import os

@testable import InnerTubeKit
@testable import SmartTubeIOS
@testable import SmartTubeIOSCore

// MARK: - Fakes

/// Deterministic `DownloadFetching` fake: resolves to a configured plan and "assembles" by
/// writing a small file, recording which staged parts it was given.
private final class FakeFetcher: DownloadFetching, @unchecked Sendable {
    enum Plan {
        case muxed
        case adaptive
        case resolveFails(String)
    }

    private struct State {
        var plans: [String: Plan] = [:]
        var resolved: [String] = []
        var assembled: [(videoId: String, parts: Set<DownloadPart>)] = []
        var audioOnlyRequests: [String: Bool] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setPlan(_ plan: Plan, for id: String) { state.withLock { $0.plans[id] = plan } }
    var resolved: [String] { state.withLock { $0.resolved } }
    var assembled: [(videoId: String, parts: Set<DownloadPart>)] { state.withLock { $0.assembled } }

    var audioOnlyRequests: [String: Bool] { state.withLock { $0.audioOnlyRequests } }

    func resolve(video: Video, audioOnly: Bool) async throws -> DownloadPlan {
        state.withLock { $0.audioOnlyRequests[video.id] = audioOnly }
        guard audioOnly else { return try await resolve(video: video) }
        guard let url = URL(string: "https://cdn.test/\(video.id)/audio") else {
            throw DownloadFetchError(message: "invalid test URL")
        }
        return DownloadPlan(parts: [
            .init(part: .audio, url: url, userAgent: "UA/1")
        ])
    }

    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func resolve(video: Video) async throws -> DownloadPlan {
        let plan = state.withLock { current -> Plan in
            current.resolved.append(video.id)
            return current.plans[video.id] ?? .muxed
        }
        let ua = "UA/1"
        switch plan {
        case .resolveFails(let message):
            throw DownloadFetchError(message: message)
        case .muxed:
            guard let url = URL(string: "https://cdn.test/\(video.id)") else {
                throw DownloadFetchError(message: "invalid test URL")
            }
            return DownloadPlan(parts: [
                .init(part: .muxed, url: url, userAgent: ua)
            ])
        case .adaptive:
            guard let videoURL = URL(string: "https://cdn.test/\(video.id)/v"),
                let audioURL = URL(string: "https://cdn.test/\(video.id)/a")
            else {
                throw DownloadFetchError(message: "invalid test URL")
            }
            return DownloadPlan(parts: [
                .init(part: .video, url: videoURL, userAgent: ua),
                .init(part: .audio, url: audioURL, userAgent: ua),
            ])
        }
    }

    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func assemble(videoId: String, stagedParts: [DownloadPart: URL]) async throws -> URL {
        for url in stagedParts.values where !FileManager.default.fileExists(atPath: url.path) {
            throw DownloadFetchError(message: "staged file missing")
        }
        state.withLock { $0.assembled.append((videoId, Set(stagedParts.keys))) }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fake-\(UUID().uuidString).mp4")
        try Data("video-\(videoId)".utf8).write(to: url)
        return url
    }
}

/// `BackgroundTransferring` fake. Tests drive it by "finishing" parts, which writes the staged
/// file exactly like the real delegate does and then emits the event.
private final class FakeTransfer: BackgroundTransferring, @unchecked Sendable {
    let events: AsyncStream<BackgroundTransferEvent>
    let staging: DownloadStaging
    private let continuation: AsyncStream<BackgroundTransferEvent>.Continuation

    private struct State {
        var started: [DownloadTransferID] = []
        var live: Set<DownloadTransferID> = []
        var cancelled: [String] = []
        var eventsFinished = 0
        var paused: [String] = []
        var resumed: [String] = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(staging: DownloadStaging) {
        self.staging = staging
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    var started: [DownloadTransferID] { state.withLock { $0.started } }
    var startedVideoIds: [String] { started.map(\.videoId) }
    var cancelled: [String] { state.withLock { $0.cancelled } }
    var eventsFinished: Int { state.withLock { $0.eventsFinished } }

    func setLive(_ ids: Set<DownloadTransferID>) { state.withLock { $0.live = ids } }

    func start(_ id: DownloadTransferID, url: URL, userAgent: String, headers: [String: String]) {
        state.withLock {
            $0.started.append(id)
            $0.live.insert(id)
        }
    }

    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func liveTransfers() async -> Set<DownloadTransferID> { state.withLock { $0.live } }

    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func cancel(videoId: String) async {
        state.withLock {
            $0.cancelled.append(videoId)
            $0.live = $0.live.filter { $0.videoId != videoId }
        }
    }

    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func pause(videoId: String) async { state.withLock { $0.paused.append(videoId) } }
    // Reason: protocol witness must stay async.
    // swiftlint:disable:next async_without_await
    func resume(videoId: String) async { state.withLock { $0.resumed.append(videoId) } }
    var paused: [String] { state.withLock { $0.paused } }
    var resumed: [String] { state.withLock { $0.resumed } }

    @MainActor func backgroundEventsDidFinish() { state.withLock { $0.eventsFinished += 1 } }

    // Test drivers

    func finish(_ id: DownloadTransferID) throws {
        let url = staging.stagedFile(videoId: id.videoId, part: id.part)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bytes-\(id.taskDescription)".utf8).write(to: url)
        state.withLock { _ = $0.live.remove(id) }
        continuation.yield(.staged(id))
    }

    func emit(_ event: BackgroundTransferEvent) { continuation.yield(event) }
}

@MainActor
private final class FakeWorkScope: BackgroundWorkScope {
    private(set) var begun = 0
    private(set) var ended = 0
    func begin(onExpire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        begun += 1
        var done = false
        return { [self] in
            guard !done else { return }
            done = true
            ended += 1
        }
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

private func makeTempDirectory(_ name: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
}

private struct Harness {
    let service: VideoDownloadService
    let store: DownloadStore
    let transfer: FakeTransfer
    let fetcher: FakeFetcher
    let scope: FakeWorkScope
}

@MainActor
private func makeHarness(
    store existing: DownloadStore? = nil, fetcher: FakeFetcher = FakeFetcher(),
    maxConcurrent: Int = DownloadTuning.maxConcurrent
) -> Harness {
    let store = existing ?? DownloadStore(directory: makeTempDirectory("VideoDownloadServiceTests"))
    let transfer = FakeTransfer(staging: store.staging)
    let scope = FakeWorkScope()
    let service = VideoDownloadService(
        store: store, fetcher: fetcher, transfer: transfer, workScope: scope, maxConcurrent: maxConcurrent,
        liveActivitiesEnabled: false, autoRecover: false)
    return Harness(service: service, store: store, transfer: transfer, fetcher: fetcher, scope: scope)
}

private func tid(_ videoId: String, _ part: DownloadPart) -> DownloadTransferID {
    DownloadTransferID(videoId: videoId, part: part)
}

// MARK: - Queue tests

@Suite("VideoDownloadService queue")
@MainActor
struct VideoDownloadServiceTests {

    @Test("A staged muxed part is remuxed, finalized, and its staging removed")
    func successCompletes() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("ok1"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["ok1"] })
        #expect(harness.store.entry(for: "ok1")?.status == .downloading)

        try harness.transfer.finish(tid("ok1", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "ok1")?.status == .complete })
        let entry = try #require(harness.store.entry(for: "ok1"))
        #expect(FileManager.default.fileExists(atPath: harness.store.fileURL(for: entry).path))
        #expect(entry.progress == 1)
        #expect(harness.fetcher.assembled.count == 1)
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "ok1").path))
        #expect(harness.scope.begun == harness.scope.ended)
        #expect(harness.scope.begun >= 2)  // start phase + post-processing
    }

    @Test("A resolve failure ends failed with the error message and starts no transfer")
    func resolveFailureMarksFailed() async {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.resolveFails("boom"), for: "bad1")
        let harness = makeHarness(fetcher: fetcher)
        harness.service.enqueue(video: makeVideo("bad1"))
        #expect(await waitUntil { harness.store.entry(for: "bad1")?.status == .failed })
        #expect(harness.store.entry(for: "bad1")?.errorMessage == "boom")
        #expect(harness.transfer.started.isEmpty)
    }

    @Test("A failed transfer (e.g. expired link) marks failed, cleans staging, and is not retried")
    func transferFailureDoesNotLoop() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("exp"))
        #expect(await waitUntil { harness.transfer.started.count == 1 })
        harness.transfer.emit(.failed(tid("exp", .muxed), message: "The download link expired (HTTP 403)."))
        #expect(await waitUntil { harness.store.entry(for: "exp")?.status == .failed })
        #expect(harness.store.entry(for: "exp")?.errorMessage == "The download link expired (HTTP 403).")
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "exp").path))
        await Task.yield()
        #expect(harness.fetcher.resolved == ["exp"])
        #expect(harness.transfer.started.count == 1)
    }

    @Test("Progress events update the entry")
    func progressUpdatesEntry() async {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("p1"))
        #expect(await waitUntil { harness.transfer.started.count == 1 })
        harness.transfer.emit(.progress(tid("p1", .muxed), written: 50, expected: 100))
        #expect(await waitUntil { harness.store.entry(for: "p1")?.progress == 0.5 })
    }

    @Test("Enqueueing the same video twice resolves it once")
    func duplicateEnqueueIgnored() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("dup"))
        harness.service.enqueue(video: makeVideo("dup"))
        #expect(await waitUntil { harness.transfer.started.count == 1 })
        try harness.transfer.finish(tid("dup", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "dup")?.status == .complete })
        harness.service.enqueue(video: makeVideo("dup"))
        await Task.yield()
        #expect(harness.fetcher.resolved == ["dup"])
        #expect(harness.store.entries.count == 1)
    }

    @Test("At most maxConcurrent run at once and items start in FIFO order")
    func concurrencyAndOrdering() async throws {
        let harness = makeHarness(maxConcurrent: 2)
        for id in ["a", "b", "c", "d"] { harness.service.enqueue(video: makeVideo(id)) }

        #expect(await waitUntil { harness.transfer.started.count == 2 })
        #expect(harness.transfer.startedVideoIds == ["a", "b"])
        #expect(harness.store.entry(for: "c")?.status == .queued)
        #expect(harness.store.entry(for: "d")?.status == .queued)

        try harness.transfer.finish(tid("a", .muxed))
        #expect(await waitUntil { harness.transfer.started.count == 3 })
        #expect(harness.transfer.startedVideoIds == ["a", "b", "c"])
        #expect(await waitUntil { harness.store.entry(for: "a")?.status == .complete })

        try harness.transfer.finish(tid("b", .muxed))
        #expect(await waitUntil { harness.transfer.started.count == 4 })
        try harness.transfer.finish(tid("c", .muxed))
        try harness.transfer.finish(tid("d", .muxed))
        #expect(
            await waitUntil { ["a", "b", "c", "d"].allSatisfy { harness.store.entry(for: $0)?.status == .complete } })
        #expect(harness.transfer.startedVideoIds == ["a", "b", "c", "d"])
    }

    @Test("Retry re-resolves a failed download and can then succeed")
    func retryAfterFailure() async throws {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.resolveFails("nope"), for: "r1")
        let harness = makeHarness(fetcher: fetcher)
        harness.service.enqueue(video: makeVideo("r1"))
        #expect(await waitUntil { harness.store.entry(for: "r1")?.status == .failed })

        fetcher.setPlan(.muxed, for: "r1")
        harness.service.retry(videoId: "r1")
        #expect(await waitUntil { harness.transfer.started.count == 1 })
        try harness.transfer.finish(tid("r1", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "r1")?.status == .complete })
        #expect(fetcher.resolved == ["r1", "r1"])
    }

    @Test("Cancelling a queued item removes it from the queue without resolving")
    func cancelQueued() async throws {
        let harness = makeHarness(maxConcurrent: 1)
        harness.service.enqueue(video: makeVideo("x"))
        harness.service.enqueue(video: makeVideo("y"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["x"] })
        harness.service.cancel(videoId: "y")
        #expect(harness.store.entry(for: "y")?.status == .failed)
        try harness.transfer.finish(tid("x", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "x")?.status == .complete })
        #expect(harness.fetcher.resolved == ["x"])
    }

    @Test("Cancelling a running download cancels its transfers and deletes its staging")
    func cancelRunningCleansUp() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("run"))
        #expect(await waitUntil { harness.transfer.started.count == 1 })
        #expect(FileManager.default.fileExists(atPath: harness.store.staging.jobURL(for: "run").path))

        harness.service.cancel(videoId: "run")
        #expect(harness.store.entry(for: "run")?.status == .failed)
        #expect(harness.store.entry(for: "run")?.errorMessage == "Cancelled")
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "run").path))
        #expect(await waitUntil { harness.transfer.cancelled == ["run"] })

        // A late staged event for the cancelled item must not resurrect it.
        try harness.transfer.finish(tid("run", .muxed))
        await Task.yield()
        #expect(
            await waitUntil {
                !FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "run").path)
            })
        #expect(harness.store.entry(for: "run")?.status == .failed)
        #expect(harness.fetcher.assembled.isEmpty)
    }

    @Test("The background-events completion is relayed after events are handled")
    func eventsFinishedRelayed() async {
        let harness = makeHarness()
        harness.transfer.emit(.sessionEventsFinished)
        #expect(await waitUntil { harness.transfer.eventsFinished == 1 })
    }
}

// MARK: - Multi-part and job-record tests

@Suite("VideoDownloadService background parts")
@MainActor
struct VideoDownloadServiceBackgroundTests {

    @Test("Adaptive downloads merge only after both parts are staged")
    func mergeWaitsForBothParts() async throws {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.adaptive, for: "ad")
        let harness = makeHarness(fetcher: fetcher)
        harness.service.enqueue(video: makeVideo("ad"))
        #expect(await waitUntil { harness.transfer.started.count == 2 })
        #expect(Set(harness.transfer.started.map(\.part)) == [.video, .audio])

        try harness.transfer.finish(tid("ad", .video))
        #expect(await waitUntil { harness.store.entry(for: "ad")?.progress == 0.5 })
        #expect(harness.fetcher.assembled.isEmpty)
        #expect(harness.store.entry(for: "ad")?.status == .downloading)

        try harness.transfer.finish(tid("ad", .audio))
        #expect(await waitUntil { harness.store.entry(for: "ad")?.status == .complete })
        #expect(harness.fetcher.assembled.count == 1)
        #expect(harness.fetcher.assembled.first?.parts == [.video, .audio])
    }

    @Test("The job record is persisted with expected parts and updated as parts finish")
    func jobRecordPersistence() async throws {
        let fetcher = FakeFetcher()
        fetcher.setPlan(.adaptive, for: "job")
        let harness = makeHarness(fetcher: fetcher)
        harness.service.enqueue(video: makeVideo("job"))
        #expect(await waitUntil { harness.transfer.started.count == 2 })

        let initial = try #require(harness.store.staging.load(videoId: "job"))
        #expect(initial.expectedParts == [.video, .audio])
        #expect(initial.needsMerge)
        #expect(initial.donePartNames.isEmpty)
        #expect(initial.plan.parts.allSatisfy { $0.userAgent == "UA/1" })

        try harness.transfer.finish(tid("job", .video))
        #expect(await waitUntil { harness.store.staging.load(videoId: "job")?.donePartNames == [.video] })
    }
}

// MARK: - Relaunch re-attach

@Suite("VideoDownloadService relaunch recovery")
@MainActor
struct VideoDownloadServiceRecoveryTests {

    /// Simulates the previous launch: an in-flight manifest entry plus (optionally) a job record
    /// and staged files on disk, then builds a fresh store + service over the same directory.
    private func relaunch(
        videoId: String, status: DownloadedVideo.Status, plan: DownloadPlan?,
        staged: [DownloadPart] = [], live: Set<DownloadTransferID> = []
    ) throws -> Harness {
        let dir = makeTempDirectory("Recovery")
        let previous = DownloadStore(directory: dir)
        previous.upsert(
            DownloadedVideo(
                videoId: videoId, title: "T", channelTitle: "C", thumbnailURL: nil, duration: 5,
                fileName: previous.fileName(for: videoId), downloadedAt: Date(), status: status))
        if let plan {
            try previous.staging.save(DownloadJob(videoId: videoId, plan: plan))
            for part in staged {
                let url = previous.staging.stagedFile(videoId: videoId, part: part)
                try Data("x".utf8).write(to: url)
            }
        }
        let store = DownloadStore(directory: dir)  // the new launch; reconcile must not fail it
        let harness = makeHarness(store: store)
        harness.transfer.setLive(live)
        return harness
    }

    private func plan(_ id: String, _ parts: [DownloadPart]) throws -> DownloadPlan {
        DownloadPlan(
            parts: try parts.map {
                guard let url = URL(string: "https://cdn.test/\(id)/\($0.rawValue)") else {
                    throw DownloadFetchError(message: "invalid test URL")
                }
                return .init(part: $0, url: url, userAgent: "UA")
            })
    }

    @Test("A live task keeps the entry downloading and its completion finishes the download")
    func liveTaskReattaches() async throws {
        let harness = try relaunch(
            videoId: "live", status: .downloading, plan: plan("live", [.muxed]), live: [tid("live", .muxed)])
        #expect(harness.store.entry(for: "live")?.status == .downloading)  // reconcile left it alone

        await harness.service.recoverInterruptedDownloads()
        #expect(harness.store.entry(for: "live")?.status == .downloading)
        #expect(harness.fetcher.resolved.isEmpty)  // not re-resolved or restarted
        #expect(harness.transfer.started.isEmpty)

        harness.transfer.emit(.progress(tid("live", .muxed), written: 25, expected: 100))
        #expect(await waitUntil { harness.store.entry(for: "live")?.progress == 0.25 })
        try harness.transfer.finish(tid("live", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "live")?.status == .complete })
    }

    @Test("A complete staging set with no live tasks resumes post-processing")
    func stagedCompleteResumes() async throws {
        let harness = try relaunch(
            videoId: "done", status: .downloading, plan: plan("done", [.video, .audio]), staged: [.video, .audio])
        await harness.service.recoverInterruptedDownloads()
        #expect(await waitUntil { harness.store.entry(for: "done")?.status == .complete })
        #expect(harness.fetcher.assembled.first?.parts == [.video, .audio])
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "done").path))
        #expect(harness.scope.begun == harness.scope.ended)
    }

    @Test("An entry that was merging when the app died resumes the merge")
    func mergingResumes() async throws {
        let harness = try relaunch(videoId: "mrg", status: .merging, plan: plan("mrg", [.muxed]), staged: [.muxed])
        await harness.service.recoverInterruptedDownloads()
        #expect(await waitUntil { harness.store.entry(for: "mrg")?.status == .complete })
    }

    @Test("No live task and no staging data fails as Interrupted")
    func nothingFails() async throws {
        let harness = try relaunch(videoId: "gone", status: .downloading, plan: nil)
        await harness.service.recoverInterruptedDownloads()
        #expect(harness.store.entry(for: "gone")?.status == .failed)
        #expect(harness.store.entry(for: "gone")?.errorMessage == "Interrupted")
    }

    @Test("A queued entry from the previous launch fails as Interrupted")
    func queuedFails() async throws {
        let harness = try relaunch(videoId: "q", status: .queued, plan: nil)
        await harness.service.recoverInterruptedDownloads()
        #expect(harness.store.entry(for: "q")?.errorMessage == "Interrupted")
    }

    @Test("Partial staging without a live task fails and is cleaned up")
    func partialStagingFails() async throws {
        let harness = try relaunch(
            videoId: "half", status: .downloading, plan: plan("half", [.video, .audio]), staged: [.video])
        await harness.service.recoverInterruptedDownloads()
        #expect(harness.store.entry(for: "half")?.status == .failed)
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "half").path))
    }

    @Test("Orphaned staging directories are removed")
    func orphanStagingRemoved() async throws {
        let harness = try relaunch(videoId: "keep", status: .complete, plan: nil)
        try harness.store.staging.save(DownloadJob(videoId: "orphan", plan: plan("orphan", [.muxed])))
        await harness.service.recoverInterruptedDownloads()
        #expect(!FileManager.default.fileExists(atPath: harness.store.staging.directory(for: "orphan").path))
    }

    @Test("A staged event arriving before recovery runs is attached to its persisted job")
    func eventBeforeRecovery() async throws {
        let harness = try relaunch(
            videoId: "early", status: .downloading, plan: plan("early", [.muxed]), live: [tid("early", .muxed)])
        try harness.transfer.finish(tid("early", .muxed))
        #expect(await waitUntil { harness.store.entry(for: "early")?.status == .complete })
        await harness.service.recoverInterruptedDownloads()  // must be a no-op now
        #expect(harness.store.entry(for: "early")?.status == .complete)
        #expect(harness.fetcher.assembled.count == 1)
    }
}

// MARK: - Audio-only

@Suite("VideoDownloadService audio-only")
@MainActor
struct VideoDownloadServiceAudioOnlyTests {

    @Test("An audio-only enqueue resolves audio-only, transfers one audio part and completes")
    func audioOnlyCompletes() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("aud1"), audioOnly: true)
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["aud1"] })
        #expect(harness.fetcher.audioOnlyRequests["aud1"] == true)
        #expect(harness.transfer.started.map(\.part) == [.audio])
        #expect(harness.store.entry(for: "aud1")?.isAudioOnly == true)

        try harness.transfer.finish(tid("aud1", .audio))
        #expect(await waitUntil { harness.store.entry(for: "aud1")?.status == .complete })
        #expect(harness.fetcher.assembled.first?.parts == [.audio])
    }

    @Test("A normal enqueue is not audio-only")
    func normalIsNotAudioOnly() async {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("vid1"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["vid1"] })
        #expect(harness.fetcher.audioOnlyRequests["vid1"] == false)
        #expect(harness.store.entry(for: "vid1")?.isAudioOnly == false)
    }

    @Test("Retrying a failed audio-only download stays audio-only")
    func retryKeepsAudioOnly() async {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("aud2"), audioOnly: true)
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["aud2"] })
        harness.transfer.emit(.failed(tid("aud2", .audio), message: "expired"))
        #expect(await waitUntil { harness.store.entry(for: "aud2")?.status == .failed })

        harness.service.retry(videoId: "aud2")
        #expect(await waitUntil { harness.store.entry(for: "aud2")?.status == .downloading })
        #expect(harness.store.entry(for: "aud2")?.isAudioOnly == true)
    }

    @Test("Old manifests without isAudioOnly decode as video downloads")
    func legacyManifestDecodes() throws {
        let json = """
            {"videoId":"x","title":"T","channelTitle":"C","duration":1,"fileName":"x.mp4",
             "downloadedAt":1000,"status":"complete","progress":1}
            """
        let entry = try JSONDecoder().decode(DownloadedVideo.self, from: Data(json.utf8))
        #expect(entry.isAudioOnly == false)
        let round = try JSONDecoder().decode(DownloadedVideo.self, from: JSONEncoder().encode(entry))
        #expect(round.isAudioOnly == false)
    }
}

// MARK: - Pause / resume

@Suite("VideoDownloadService pause/resume")
@MainActor
struct VideoDownloadServicePauseTests {

    @Test("Pause suspends the transfers and flags the entry; resume undoes it")
    func pauseAndResume() async {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("p1"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["p1"] })

        harness.service.pause(videoId: "p1")
        #expect(harness.store.entry(for: "p1")?.isPaused == true)
        #expect(await waitUntil { harness.transfer.paused == ["p1"] })
        #expect(harness.store.entry(for: "p1")?.status == .downloading)

        harness.service.resume(videoId: "p1")
        #expect(harness.store.entry(for: "p1")?.isPaused == false)
        #expect(await waitUntil { harness.transfer.resumed == ["p1"] })
    }

    @Test("Pause is ignored for a queued or unknown download")
    func pauseIgnoredWhenNotRunning() async {
        let harness = makeHarness(maxConcurrent: 1)
        harness.service.enqueue(video: makeVideo("run"))
        harness.service.enqueue(video: makeVideo("wait"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["run"] })
        harness.service.pause(videoId: "wait")
        harness.service.pause(videoId: "nope")
        await Task.yield()
        #expect(harness.store.entry(for: "wait")?.isPaused == false)
        #expect(harness.transfer.paused.isEmpty)
    }

    @Test("Finishing or failing clears the paused flag")
    func statusChangeClearsPaused() async throws {
        let harness = makeHarness()
        harness.service.enqueue(video: makeVideo("p2"))
        #expect(await waitUntil { harness.transfer.startedVideoIds == ["p2"] })
        harness.service.pause(videoId: "p2")
        harness.store.setStatus(videoId: "p2", status: .failed, error: "x")
        #expect(harness.store.entry(for: "p2")?.isPaused == false)
    }

    @Test("Old manifests without isPaused decode as not paused")
    func legacyDecode() throws {
        let json = """
            {"videoId":"x","title":"T","channelTitle":"C","duration":1,"fileName":"x.mp4",
             "downloadedAt":1000,"status":"downloading","progress":0.4}
            """
        let entry = try JSONDecoder().decode(DownloadedVideo.self, from: Data(json.utf8))
        #expect(entry.isPaused == false)
    }
}
