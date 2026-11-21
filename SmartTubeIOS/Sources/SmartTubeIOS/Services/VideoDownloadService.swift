import Foundation
import Observation
import SmartTubeIOSCore
import os

#if os(iOS)
@preconcurrency import ActivityKit
#endif

private let downloadLog = CrashlyticsLogger(category: "Download")

// MARK: - VideoDownloadService
//
// FIFO download queue for the personal downloads library. Files land in app storage only
// (`DownloadStore`); there is no Photos export. Per-item progress and status live in
// `DownloadStore.entries`.
//
// Pipeline per video: `DownloadFetching.resolve` (foreground, quick) -> a persisted
// `DownloadJob` + one background `URLSession` transfer per part -> the transfer layer stages
// each finished part under `Staging/<videoId>` and reports it -> when every part is staged,
// `DownloadFetching.assemble` (merge + remux, inside a UIKit background task) ->
// `DownloadStore.finalize`. Transfers keep running while the app is suspended or not running;
// `recoverInterruptedDownloads()` re-attaches on the next launch.
// At most `DownloadTuning.maxConcurrent` items run at once.

@MainActor
@Observable
public final class VideoDownloadService {

    // MARK: - Aggregate state (drives completion alerts and the Live Activity)

    public enum DownloadState: Equatable {
        case idle
        case fetching
        case downloading(progress: Double)
        case saving
        case done
        case failed(String)

        public var isActive: Bool {
            switch self {
            case .fetching, .downloading, .saving: return true
            default: return false
            }
        }
    }

    /// Aggregate of the queue: active while anything is queued/running; `.done` / `.failed`
    /// are momentary results the UI resets via `reset()` after showing an alert.
    public private(set) var state: DownloadState = .idle

    /// `true` while an AVPlayer `PlayerView` is on screen and is showing the completion
    /// alert itself (with the video's title). `RootView` skips its own alert then, so a
    /// finished download never produces two alerts.
    public var playerOwnsCompletionAlert = false

    // MARK: - Private

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let fetcher: any DownloadFetching
    @ObservationIgnored private let transfer: any BackgroundTransferring
    @ObservationIgnored private let workScope: any BackgroundWorkScope
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private let liveActivitiesEnabled: Bool
    @ObservationIgnored private var pending: [Video] = []
    /// Videos occupying a concurrency slot (resolving, transferring or post-processing).
    @ObservationIgnored private var active: Set<String> = []
    @ObservationIgnored private var starting: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var postProcessing: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var cancelling: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var jobs: [String: DownloadJob] = [:]
    @ObservationIgnored private var fractions: [String: [DownloadPart: Double]] = [:]
    /// The item whose progress drives the aggregate state and the Live Activity.
    @ObservationIgnored private var leadVideoId: String?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?

    #if os(iOS)
    @available(iOS 16.1, *)
    @ObservationIgnored
    private var liveActivity: Activity<DownloadActivityAttributes>?
    #endif

    private var staging: DownloadStaging { transfer.staging }

    // MARK: - Init

    /// - Parameter autoRecover: re-attach to background transfers left over from a previous
    ///   launch right away. Tests pass `false` and call `recoverInterruptedDownloads()` themselves.
    public init(
        api: InnerTubeAPI = InnerTubeAPI(),
        store: DownloadStore = .shared,
        fetcher: (any DownloadFetching)? = nil,
        transfer: (any BackgroundTransferring)? = nil,
        workScope: (any BackgroundWorkScope)? = nil,
        maxConcurrent: Int = DownloadTuning.maxConcurrent,
        liveActivitiesEnabled: Bool = true,
        autoRecover: Bool = true
    ) {
        self.store = store
        self.fetcher = fetcher ?? ConfigurableDownloadFetcher(native: InnerTubeDownloadFetcher(api: api))
        self.transfer = transfer ?? BackgroundDownloadSession.shared
        self.workScope = workScope ?? SystemBackgroundWorkScope()
        self.maxConcurrent = max(1, maxConcurrent)
        self.liveActivitiesEnabled = liveActivitiesEnabled

        let events = self.transfer.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self else { break }
                self.handle(event)
            }
        }
        if autoRecover {
            recoveryTask = Task { [weak self] in await self?.recoverInterruptedDownloads() }
        }
    }

    // MARK: - Public

    /// Queues `video` for download. Ignored if it is already queued, downloading, merging or
    /// complete. A previously failed entry is re-queued.
    public func enqueue(video: Video, audioOnly: Bool = false) {
        if let existing = store.entry(for: video.id) {
            switch existing.status {
            case .queued, .downloading, .merging, .complete: return
            case .failed: break
            }
        }
        store.upsert(
            DownloadedVideo(
                videoId: video.id,
                title: video.title,
                channelTitle: video.channelTitle,
                thumbnailURL: video.thumbnailURL,
                duration: video.duration ?? 0,
                fileName: store.fileName(for: video.id),
                downloadedAt: Date(),
                status: .queued,
                isAudioOnly: audioOnly))
        pending.append(video)
        if !state.isActive { state = .fetching }
        pump()
    }

    /// Current download status of `videoId`, or `nil` if it was never queued.
    public func status(for videoId: String) -> DownloadedVideo.Status? {
        store.entry(for: videoId)?.status
    }

    /// Compatibility shim for call sites written against the single-download API.
    public func download(video: Video) {
        enqueue(video: video)
    }

    /// Cancels a queued or running download: stops its transfers and deletes its staging data.
    /// The entry is kept (as failed "Cancelled") so the user can retry; call
    /// `DownloadStore.remove` to delete it.
    public func cancel(videoId: String) {
        pending.removeAll { $0.id == videoId }
        guard let entry = store.entry(for: videoId), Self.isInFlight(entry.status) else { return }
        fail(videoId: videoId, message: Self.cancelledMessage)
    }

    /// Pauses a running download (suspends its transfers; progress is kept). No-op unless the
    /// entry is `.downloading` with transfers started.
    public func pause(videoId: String) {
        guard let entry = store.entry(for: videoId), entry.status == .downloading, !entry.isPaused,
            jobs[videoId] != nil
        else { return }
        store.setPaused(videoId: videoId, true)
        Task { await transfer.pause(videoId: videoId) }
    }

    /// Resumes a paused download.
    public func resume(videoId: String) {
        guard let entry = store.entry(for: videoId), entry.status == .downloading, entry.isPaused else { return }
        store.setPaused(videoId: videoId, false)
        Task { await transfer.resume(videoId: videoId) }
    }

    /// Re-queues a failed download. The stream URLs are resolved again, so an expired link is fine.
    public func retry(videoId: String) {
        guard let entry = store.entry(for: videoId), entry.status == .failed else { return }
        enqueue(
            video: Video(
                id: entry.videoId,
                title: entry.title,
                channelTitle: entry.channelTitle,
                thumbnailURL: entry.thumbnailURL,
                duration: entry.duration),
            audioOnly: entry.isAudioOnly)
    }

    /// Clears a momentary `.done` / `.failed` result after the UI has shown it.
    public func reset() {
        if !state.isActive { state = .idle }
    }

    // MARK: - Recovery

    /// Reconciles in-flight entries left over from a previous launch with what the background
    /// session actually still has:
    /// - live transfers: re-attach, the entry stays `downloading` and progress continues;
    /// - every part staged but nothing live: resume post-processing;
    /// - neither: `failed("Interrupted")`.
    public func recoverInterruptedDownloads() async {
        let live = await transfer.liveTransfers()
        for entry in store.entries where Self.isInFlight(entry.status) {
            let id = entry.videoId
            if active.contains(id) || pending.contains(where: { $0.id == id }) { continue }
            guard let job = staging.load(videoId: id) else {
                failInterrupted(videoId: id)
                continue
            }
            let hasLiveTransfer = live.contains { $0.videoId == id }
            if hasLiveTransfer {
                adopt(job, status: .downloading)
                refreshAggregate()
            } else if job.isComplete {
                adopt(job, status: .merging)
                startPostProcessing(videoId: id)
            } else {
                failInterrupted(videoId: id)
            }
        }
        // Staging left behind by entries that no longer exist or are no longer in flight.
        if let names = try? FileManager.default.contentsOfDirectory(atPath: staging.root.path) {
            for name in names {
                let inFlight = store.entry(for: name).map { Self.isInFlight($0.status) } ?? false
                if !inFlight && !active.contains(name) { staging.remove(videoId: name) }
            }
        }
        pump()
    }

    private func adopt(_ job: DownloadJob, status: DownloadedVideo.Status) {
        let id = job.videoId
        jobs[id] = job
        active.insert(id)
        fractions[id] = Dictionary(uniqueKeysWithValues: job.donePartNames.map { ($0, 1.0) })
        store.setStatus(videoId: id, status: status)
        if let entry = store.entry(for: id) { promoteLead(id, title: entry.title) }
    }

    private func failInterrupted(videoId: String) {
        staging.remove(videoId: videoId)
        store.setStatus(videoId: videoId, status: .failed, error: Self.interruptedMessage)
        store.setProgress(videoId: videoId, progress: 0)
        refreshAggregate()
    }

    // MARK: - Queue

    private static let cancelledMessage = "Cancelled"
    private static let interruptedMessage = "Interrupted"

    private static func isInFlight(_ status: DownloadedVideo.Status) -> Bool {
        switch status {
        case .queued, .downloading, .merging: return true
        case .complete, .failed: return false
        }
    }

    private func pump() {
        while active.count < maxConcurrent, !pending.isEmpty {
            let video = pending.removeFirst()
            guard store.entry(for: video.id)?.status == .queued else { continue }
            active.insert(video.id)
            starting[video.id] = Task { [weak self] in
                await self?.begin(video)
            }
        }
    }

    /// Resolves the streams, persists the job record, and hands each part to the transfer layer.
    private func begin(_ video: Video) async {
        let id = video.id
        store.setStatus(videoId: id, status: .downloading)
        store.setProgress(videoId: id, progress: 0)
        promoteLead(id, title: video.title)
        refreshAggregate()

        let endWork = workScope.begin(onExpire: {})
        defer { endWork() }
        // A cancel followed by a quick retry must not have the old cancel hit the new transfers.
        await cancelling[id]?.value
        do {
            let audioOnly = store.entry(for: id)?.isAudioOnly ?? false
            let plan = try await fetcher.resolve(video: video, audioOnly: audioOnly)
            try Task.checkCancellation()
            let job = DownloadJob(videoId: id, plan: plan)
            try staging.save(job)
            jobs[id] = job
            fractions[id] = [:]
            starting[id] = nil
            for part in plan.parts {
                transfer.start(
                    DownloadTransferID(videoId: id, part: part.part), url: part.url, userAgent: part.userAgent,
                    headers: part.headers)
            }
        } catch is CancellationError {
            // `cancel` already cleaned up.
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            downloadLog.error("[download] ❌ \(id) failed to start: \(error.localizedDescription)")
            fail(videoId: id, message: error.localizedDescription)
        }
    }

    // MARK: - Transfer events

    private func handle(_ event: BackgroundTransferEvent) {
        switch event {
        case .progress(let id, let written, let expected):
            guard expected > 0, let job = trackedJob(id.videoId),
                store.entry(for: id.videoId)?.status == .downloading
            else { return }
            fractions[id.videoId, default: [:]][id.part] = min(Double(written) / Double(expected), 1)
            let parts = job.expectedParts
            let sum = parts.reduce(0.0) { $0 + (fractions[id.videoId]?[$1] ?? 0) }
            applyProgress(videoId: id.videoId, progress: sum / Double(max(parts.count, 1)))
        case .staged(let id):
            handleStaged(id)
        case .failed(let id, let message):
            guard trackedJob(id.videoId) != nil || active.contains(id.videoId) else { return }
            downloadLog.error("[download] ❌ \(id.taskDescription) failed: \(message)")
            fail(videoId: id.videoId, message: message)
        case .sessionEventsFinished:
            // Relayed through the ordered stream so any post-processing background task has
            // already begun before the system is told it may suspend us again.
            transfer.backgroundEventsDidFinish()
        }
    }

    /// The job for an in-flight video: the in-memory one, or (events can arrive before
    /// `recoverInterruptedDownloads` has run after a relaunch) the one persisted on disk.
    private func trackedJob(_ videoId: String) -> DownloadJob? {
        if let job = jobs[videoId] { return job }
        guard let entry = store.entry(for: videoId), Self.isInFlight(entry.status),
            !pending.contains(where: { $0.id == videoId }),
            let job = staging.load(videoId: videoId)
        else { return nil }
        adopt(job, status: entry.status == .merging ? .merging : .downloading)
        return job
    }

    private func handleStaged(_ id: DownloadTransferID) {
        let videoId = id.videoId
        guard var job = trackedJob(videoId), store.entry(for: videoId) != nil else {
            // Late event for something cancelled or removed: drop its bytes.
            if !active.contains(videoId) { staging.remove(videoId: videoId) }
            return
        }
        job.donePartNames.insert(id.part)
        jobs[videoId] = job
        try? staging.save(job)
        fractions[videoId, default: [:]][id.part] = 1
        if job.isComplete {
            startPostProcessing(videoId: videoId)
        } else {
            let parts = job.expectedParts
            let sum = parts.reduce(0.0) { $0 + (fractions[videoId]?[$1] ?? 0) }
            applyProgress(videoId: videoId, progress: sum / Double(max(parts.count, 1)))
        }
    }

    private func applyProgress(videoId: String, progress p: Double) {
        store.setProgress(videoId: videoId, progress: p)
        guard videoId == leadVideoId else { return }
        refreshAggregate()
        #if os(iOS)
        if liveActivitiesEnabled, #available(iOS 16.1, *) {
            Task { await updateLiveActivity(phase: .downloading, progress: p) }
        }
        #endif
    }

    // MARK: - Post-processing

    private func startPostProcessing(videoId id: String) {
        guard postProcessing[id] == nil, let job = jobs[id] else { return }
        store.setStatus(videoId: id, status: .merging)
        if id == leadVideoId {
            refreshAggregate()
            #if os(iOS)
            if liveActivitiesEnabled, #available(iOS 16.1, *) {
                Task { await updateLiveActivity(phase: .saving, progress: 1) }
            }
            #endif
        }
        // Keeps the process alive for the merge when we were only woken in the background. If the
        // system expires it anyway, the staged files remain and the next launch resumes.
        let endWork = workScope.begin(onExpire: {
            downloadLog.notice("[download] background time expired during post-processing of \(id)")
        })
        postProcessing[id] = Task { [weak self] in
            await self?.postProcess(job, endWork: endWork)
        }
    }

    private func postProcess(_ job: DownloadJob, endWork: @MainActor () -> Void) async {
        let id = job.videoId
        defer { endWork() }
        var stagedParts: [DownloadPart: URL] = [:]
        for part in job.expectedParts { stagedParts[part] = staging.stagedFile(videoId: id, part: part) }
        do {
            let audioOnly = store.entry(for: id)?.isAudioOnly ?? false
            let tempURL = try await fetcher.assemble(videoId: id, stagedParts: stagedParts, audioOnly: audioOnly)
            guard !Task.isCancelled, store.entry(for: id)?.status == .merging else {
                try? FileManager.default.removeItem(at: tempURL)
                return
            }
            if store.finalize(videoId: id, from: tempURL) {
                succeed(videoId: id)
            } else {
                try? FileManager.default.removeItem(at: tempURL)
                fail(
                    videoId: id,
                    message: store.entry(for: id)?.errorMessage ?? "Could not save the downloaded file")
            }
        } catch is CancellationError {
            // `cancel` already cleaned up.
        } catch {
            downloadLog.error("[download] ❌ \(id) post-processing failed: \(error.localizedDescription)")
            if !Task.isCancelled { fail(videoId: id, message: error.localizedDescription) }
        }
    }

    // MARK: - Completion

    private func succeed(videoId id: String) {
        postProcessing[id] = nil
        jobs[id] = nil
        fractions[id] = nil
        staging.remove(videoId: id)
        active.remove(id)
        finish(videoId: id, failure: nil)
        pump()
    }

    /// Marks `videoId` failed and releases everything it held: transfers, staging, slot.
    private func fail(videoId id: String, message: String) {
        starting[id]?.cancel()
        starting[id] = nil
        postProcessing[id]?.cancel()
        postProcessing[id] = nil
        let transfer = self.transfer
        cancelling[id] = Task { await transfer.cancel(videoId: id) }
        staging.remove(videoId: id)
        jobs[id] = nil
        fractions[id] = nil
        pending.removeAll { $0.id == id }
        let wasActive = active.remove(id) != nil
        store.setStatus(videoId: id, status: .failed, error: message)
        store.setProgress(videoId: id, progress: 0)
        if wasActive {
            finish(videoId: id, failure: message)
        } else {
            refreshAggregate()
        }
        pump()
    }

    private func finish(videoId: String, failure: String?) {
        if videoId == leadVideoId {
            leadVideoId = nil
            #if os(iOS)
            if liveActivitiesEnabled, #available(iOS 16.1, *) {
                let phase: DownloadActivityAttributes.DownloadContentState.Phase =
                    failure == nil ? .done : .failed
                Task { await endLiveActivity(phase: phase) }
            }
            #endif
        }
        // Promote another running item to lead.
        if leadVideoId == nil { leadVideoId = active.first }
        // `.done` / `.failed` are momentary results for the UI; the next progress event or
        // `reset()` restores the aggregate.
        switch failure {
        case nil: state = .done
        case Self.cancelledMessage: refreshAggregate()
        case .some(let reason): state = .failed(reason)
        }
    }

    private func promoteLead(_ id: String, title: String) {
        guard leadVideoId == nil else { return }
        leadVideoId = id
        #if os(iOS)
        if liveActivitiesEnabled, #available(iOS 16.1, *) { startLiveActivity(title: title) }
        #endif
    }

    private func refreshAggregate() {
        if case .done = state, pending.isEmpty, active.isEmpty { return }
        if case .failed = state, pending.isEmpty, active.isEmpty { return }
        guard !pending.isEmpty || !active.isEmpty else {
            state = .idle
            return
        }
        guard let lead = leadVideoId, let entry = store.entry(for: lead) else {
            state = .fetching
            return
        }
        switch entry.status {
        case .downloading: state = .downloading(progress: entry.progress)
        case .merging: state = .saving
        default: state = .fetching
        }
    }

    // MARK: - Live Activity (driven by the lead item)

    #if os(iOS)
    @available(iOS 16.1, *)
    private func startLiveActivity(title: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = DownloadActivityAttributes(videoTitle: title)
        let state = DownloadActivityAttributes.DownloadContentState(progress: 0, phase: .fetching)
        do {
            liveActivity = try Activity<DownloadActivityAttributes>.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
        } catch {
            downloadLog.notice("[download] Live Activity unavailable: \(error.localizedDescription)")
        }
    }

    @available(iOS 16.1, *)
    private func updateLiveActivity(
        phase: DownloadActivityAttributes.DownloadContentState.Phase,
        progress: Double = 0
    ) async {
        guard let activity = liveActivity else { return }
        let newState = DownloadActivityAttributes.DownloadContentState(progress: progress, phase: phase)
        // Activity<T> is a Sendable struct; dispatch the await via a nonisolated helper to
        // satisfy Swift 6 region isolation — the value is safely copied out of the @MainActor region.
        await Self.sendActivityUpdate(activity, state: newState)
    }

    @available(iOS 16.1, *)
    private func endLiveActivity(phase: DownloadActivityAttributes.DownloadContentState.Phase) async {
        guard let activity = liveActivity else { return }
        let finalState = DownloadActivityAttributes.DownloadContentState(progress: 1, phase: phase)
        liveActivity = nil  // nil out on @MainActor before sending the value across the boundary
        await Self.sendActivityEnd(activity, state: finalState)
    }

    /// Dispatches `Activity.update` from a nonisolated context.
    /// `Activity<T>` is a `Sendable` struct so transferring it via `sending` is safe.
    @available(iOS 16.1, *)
    nonisolated private static func sendActivityUpdate(
        _ activity: sending Activity<DownloadActivityAttributes>,
        state: DownloadActivityAttributes.DownloadContentState
    ) async {
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    /// Dispatches `Activity.end` from a nonisolated context. See `sendActivityUpdate` for rationale.
    @available(iOS 16.1, *)
    nonisolated private static func sendActivityEnd(
        _ activity: sending Activity<DownloadActivityAttributes>,
        state: DownloadActivityAttributes.DownloadContentState
    ) async {
        await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 4))
    }
    #endif
}
