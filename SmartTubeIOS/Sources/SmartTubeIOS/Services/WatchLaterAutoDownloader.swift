#if !os(tvOS)
import Foundation
import Network
import SmartTubeIOSCore
import os

private let autoDownloadLog = Logger(subsystem: appSubsystem, category: "AutoDownload")

// MARK: - Seams

/// Where the Watch Later list comes from. Production: the signed-in InnerTube account.
public protocol WatchLaterSource: Sendable {
    func watchLaterVideos() async throws -> [Video]
}

/// Whether the current connection may be used for automatic downloads.
public protocol NetworkConditions: Sendable {
    /// `true` on an unmetered connection (Wi-Fi / Ethernet), `false` on cellular or a hotspot.
    var isUnmetered: Bool { get }
}

extension InnerTubeAPI: WatchLaterSource {
    public func watchLaterVideos() async throws -> [Video] {
        try await fetchPlaylistVideos(playlistId: "WL", continuationToken: nil).videos
    }
}

/// `NWPathMonitor`-backed conditions. "Unmetered" = the path is satisfied and neither expensive
/// (cellular, personal hotspot) nor constrained (Low Data Mode).
public final class SystemNetworkConditions: NetworkConditions, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = OSAllocatedUnfairLock(initialState: false)

    public init() {
        monitor.pathUpdateHandler = { [lock] path in
            let ok = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            lock.withLock { $0 = ok }
        }
        // NWPathMonitor has no queue-free start in our deployment target; this is the one DispatchQueue.
        monitor.start(queue: DispatchQueue(label: "com.void.smarttube.network-conditions"))
        lock.withLock { $0 = monitor.currentPath.status == .satisfied && !monitor.currentPath.isExpensive }
    }

    deinit { monitor.cancel() }

    public var isUnmetered: Bool { lock.withLock { $0 } }
}

// MARK: - WatchLaterAutoDownloader

/// Queues newly added Watch Later videos for download. Opt-in (`autoDownloadWatchLater`), runs at
/// most every `DownloadTuning.autoDownloadMinInterval`, honours "Wi-Fi only", and only ever adds
/// downloads: nothing is deleted automatically.
@MainActor
public final class WatchLaterAutoDownloader {
    private let source: any WatchLaterSource
    private let network: any NetworkConditions
    private let enqueue: @MainActor (Video) -> Void
    private let knownVideoIds: @MainActor () -> Set<String>
    private let now: @Sendable () -> Date
    private var lastSync: Date?

    public init(
        source: any WatchLaterSource,
        network: any NetworkConditions,
        store: DownloadStore,
        service: VideoDownloadService,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.network = network
        self.enqueue = { service.enqueue(video: $0) }
        self.knownVideoIds = { Set(store.entries.map(\.videoId)) }
        self.now = now
    }

    /// Test/seam initialiser.
    init(
        source: any WatchLaterSource,
        network: any NetworkConditions,
        knownVideoIds: @escaping @MainActor () -> Set<String>,
        enqueue: @escaping @MainActor (Video) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.source = source
        self.network = network
        self.knownVideoIds = knownVideoIds
        self.enqueue = enqueue
        self.now = now
    }

    /// Runs a sync if enabled, signed in, allowed on this network, and not run too recently.
    /// - Returns: how many videos were queued (0 when skipped).
    @discardableResult
    public func syncIfDue(settings: AppSettings, isSignedIn: Bool) async -> Int {
        guard settings.autoDownloadWatchLater, isSignedIn else { return 0 }
        if settings.autoDownloadOnlyOnWiFi, !network.isUnmetered { return 0 }
        if let last = lastSync, now().timeIntervalSince(last) < DownloadTuning.autoDownloadMinInterval { return 0 }
        lastSync = now()

        do {
            let videos = try await source.watchLaterVideos()
            let picked = AutoDownloadPolicy.select(candidates: videos, knownVideoIds: knownVideoIds())
            for video in picked { enqueue(video) }
            autoDownloadLog.notice(
                "queued \(picked.count, privacy: .public) of \(videos.count, privacy: .public) Watch Later videos")
            return picked.count
        } catch {
            // Allow another attempt sooner than the full interval after a failure.
            lastSync = nil
            autoDownloadLog.error("Watch Later sync failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}
#endif
