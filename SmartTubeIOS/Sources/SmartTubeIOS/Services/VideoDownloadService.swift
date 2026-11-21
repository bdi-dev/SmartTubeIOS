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
// `DownloadStore.entries`; the network work is delegated to a `DownloadFetching` seam.
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

    // MARK: - Private

    @ObservationIgnored private let store: DownloadStore
    @ObservationIgnored private let fetcher: any DownloadFetching
    @ObservationIgnored private let maxConcurrent: Int
    @ObservationIgnored private let liveActivitiesEnabled: Bool
    @ObservationIgnored private var pending: [Video] = []
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    /// The item whose progress drives the aggregate state and the Live Activity.
    @ObservationIgnored private var leadVideoId: String?

    #if os(iOS)
    @available(iOS 16.1, *)
    @ObservationIgnored
    private var liveActivity: Activity<DownloadActivityAttributes>?
    #endif

    // MARK: - Init

    public init(
        api: InnerTubeAPI = InnerTubeAPI(),
        store: DownloadStore = .shared,
        fetcher: (any DownloadFetching)? = nil,
        maxConcurrent: Int = DownloadTuning.maxConcurrent,
        liveActivitiesEnabled: Bool = true
    ) {
        self.store = store
        self.fetcher = fetcher ?? InnerTubeDownloadFetcher(api: api)
        self.maxConcurrent = max(1, maxConcurrent)
        self.liveActivitiesEnabled = liveActivitiesEnabled
    }

    // MARK: - Public

    /// Queues `video` for download. Ignored if it is already queued, downloading, merging or
    /// complete. A previously failed entry is re-queued.
    public func enqueue(video: Video) {
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
                status: .queued))
        pending.append(video)
        if !state.isActive { state = .fetching }
        pump()
    }

    /// Compatibility shim for call sites written against the single-download API.
    public func download(video: Video) {
        enqueue(video: video)
    }

    /// Cancels a queued or running download. The entry is kept (as failed "Cancelled") so the
    /// user can retry; call `DownloadStore.remove` to delete it.
    public func cancel(videoId: String) {
        pending.removeAll { $0.id == videoId }
        if let task = running[videoId] {
            task.cancel()
        } else if store.entry(for: videoId)?.status == .queued {
            store.setStatus(videoId: videoId, status: .failed, error: "Cancelled")
            refreshAggregate()
        }
    }

    /// Re-queues a failed download.
    public func retry(videoId: String) {
        guard let entry = store.entry(for: videoId), entry.status == .failed else { return }
        enqueue(
            video: Video(
                id: entry.videoId,
                title: entry.title,
                channelTitle: entry.channelTitle,
                thumbnailURL: entry.thumbnailURL,
                duration: entry.duration))
    }

    /// Clears a momentary `.done` / `.failed` result after the UI has shown it.
    public func reset() {
        if !state.isActive { state = .idle }
    }

    // MARK: - Queue

    private func pump() {
        while running.count < maxConcurrent, !pending.isEmpty {
            let video = pending.removeFirst()
            guard store.entry(for: video.id)?.status == .queued else { continue }
            running[video.id] = Task { [weak self] in
                await self?.process(video)
            }
        }
    }

    private func process(_ video: Video) async {
        let id = video.id
        store.setStatus(videoId: id, status: .downloading)
        if leadVideoId == nil {
            leadVideoId = id
            #if os(iOS)
            if liveActivitiesEnabled, #available(iOS 16.1, *) { startLiveActivity(video: video) }
            #endif
        }
        refreshAggregate()

        var failure: String?
        do {
            let tempURL = try await fetcher.fetch(video: video) { [weak self] event in
                Task { @MainActor [weak self] in self?.handle(event, videoId: id) }
            }
            if !store.finalize(videoId: id, from: tempURL) {
                try? FileManager.default.removeItem(at: tempURL)
                failure = store.entry(for: id)?.errorMessage ?? "Could not save the downloaded file"
            }
        } catch is CancellationError {
            failure = "Cancelled"
        } catch let urlError as URLError where urlError.code == .cancelled {
            failure = "Cancelled"
        } catch {
            downloadLog.error("[download] ❌ \(id) failed: \(error.localizedDescription)")
            failure = error.localizedDescription
        }

        if let failure {
            store.setStatus(videoId: id, status: .failed, error: failure)
        }
        running[id] = nil
        await finish(videoId: id, failure: failure)
        pump()
    }

    private func handle(_ event: DownloadFetchEvent, videoId: String) {
        guard let entry = store.entry(for: videoId) else { return }
        switch event {
        case .progress(let p):
            guard entry.status == .downloading else { return }
            store.setProgress(videoId: videoId, progress: p)
            if videoId == leadVideoId { refreshAggregate() }
            #if os(iOS)
            if liveActivitiesEnabled, videoId == leadVideoId, #available(iOS 16.1, *) {
                Task { await updateLiveActivity(phase: .downloading, progress: p) }
            }
            #endif
        case .merging:
            // Ignore a late event that arrives after the item already finished.
            guard entry.status == .downloading else { return }
            store.setStatus(videoId: videoId, status: .merging)
            if videoId == leadVideoId { refreshAggregate() }
            #if os(iOS)
            if liveActivitiesEnabled, videoId == leadVideoId, #available(iOS 16.1, *) {
                Task { await updateLiveActivity(phase: .saving, progress: 1) }
            }
            #endif
        }
    }

    private func finish(videoId: String, failure: String?) async {
        if videoId == leadVideoId {
            leadVideoId = nil
            #if os(iOS)
            if liveActivitiesEnabled, #available(iOS 16.1, *) {
                await endLiveActivity(phase: failure == nil ? .done : .failed)
            }
            #endif
        }
        // Promote another running item to lead.
        if leadVideoId == nil { leadVideoId = running.keys.first }
        // `.done` / `.failed` are momentary results for the UI; the next progress event or
        // `reset()` restores the aggregate.
        switch failure {
        case nil: state = .done
        case "Cancelled": refreshAggregate()
        case .some(let reason): state = .failed(reason)
        }
    }

    private func refreshAggregate() {
        if case .done = state, pending.isEmpty, running.isEmpty { return }
        if case .failed = state, pending.isEmpty, running.isEmpty { return }
        guard !pending.isEmpty || !running.isEmpty else {
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
    private func startLiveActivity(video: Video) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let attrs = DownloadActivityAttributes(videoTitle: video.title)
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
