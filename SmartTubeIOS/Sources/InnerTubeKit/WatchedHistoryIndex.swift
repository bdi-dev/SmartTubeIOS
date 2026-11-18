import Foundation

// MARK: - WatchedHistoryIndex
//
// Fallback "already watched" signal for surfaces whose responses carry no per-viewer
// resume progress (channel pages are fetched with the WEB client, which is only
// authenticated when a SAPISID cookie value exists; TV/OAuth sessions get none).
// Holds video id -> progress (0...1) for the first few pages of the account's History
// feed, session-cached with a TTL and a size cap, and keyed to the account so a
// sign-out / account switch never leaks one account's history onto another.

public actor WatchedHistoryIndex {
    public static let shared = WatchedHistoryIndex()

    /// Progress assigned when History lists a video but its tile has no better signal.
    public static let playedFallbackProgress: Double = 1.0

    private var entries: [String: Double] = [:]
    private var loadedAt: Date?
    private var ownerKey: String?
    private var inFlight: Task<[String: Double], Never>?
    private let ttl: TimeInterval
    private let maxEntries: Int
    private let now: () -> Date

    public init(ttl: TimeInterval = 600, maxEntries: Int = 600, now: @escaping () -> Date = Date.init) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.now = now
    }

    /// Returns the cached index for `ownerKey`, loading it with `load` when missing,
    /// expired or belonging to a different account. `load` failures yield an empty index
    /// that is NOT cached, so the next call retries.
    public func index(
        ownerKey: String, load: @escaping @Sendable () async throws -> [String: Double]
    ) async -> [String: Double] {
        if self.ownerKey != ownerKey {
            entries = [:]
            loadedAt = nil
            inFlight?.cancel()
            inFlight = nil
            self.ownerKey = ownerKey
        }
        if let loadedAt, now().timeIntervalSince(loadedAt) < ttl { return entries }
        if let inFlight { return await inFlight.value }
        let task = Task<[String: Double], Never> { (try? await load()) ?? [:] }
        inFlight = task
        let result = await task.value
        // Ignore the result if the account changed while loading.
        guard self.ownerKey == ownerKey, inFlight != nil else { return result }
        inFlight = nil
        if !result.isEmpty {
            entries = Dictionary(uniqueKeysWithValues: result.prefix(maxEntries).map { ($0.key, $0.value) })
            loadedAt = now()
        }
        return result
    }

    public func reset() {
        entries = [:]
        loadedAt = nil
        ownerKey = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Fills `watchProgress` for videos that have none and appear in `index`.
    /// Never overrides a progress value the response itself carried.
    nonisolated public static func merge(_ videos: [Video], index: [String: Double]) -> [Video] {
        guard !index.isEmpty else { return videos }
        return videos.map { v in
            guard v.watchProgress == nil, let p = index[v.id] else { return v }
            var copy = v
            copy.watchProgress = p
            return copy
        }
    }
}
