import Foundation

// MARK: - WatchProgressPolicy

/// How remote (YouTube) and local (this app) watch progress combine for display.
///
/// Remote history ALWAYS supplements local history: a full watch on the web must beat a
/// 2-minute local watch, and a local watch still shows when YouTube knows nothing. The
/// shown value is simply the largest signal available.
public enum WatchProgressPolicy {
    /// Largest non-nil value, clamped to 0...1; nil when there is no signal at all.
    public static func combined(_ signals: Double?...) -> Double? {
        combined(signals)
    }

    public static func combined(_ signals: [Double?]) -> Double? {
        let present = signals.compactMap { $0 }.filter { !$0.isNaN }
        guard let best = present.max() else { return nil }
        return min(max(best, 0), 1)
    }
}

// MARK: - WatchedHistoryIndex
//
// "Already watched" signal for surfaces whose responses carry no per-viewer resume
// progress (WEB channel pages for OAuth-only TV sessions, which have no SAPISID).
// Holds video id -> progress (0...1) built from the account's History feed:
//  - the first few pages load up front (blocking, so the first paint is mostly right),
//  - further pages load lazily in the background up to a cap, posting
//    `.watchedHistoryIndexDidUpdate` so already-visible cards can refresh,
//  - the result is cached with a long TTL and persisted to Caches per account key so it
//    survives relaunch (served immediately, refreshed in the background when stale).
// Keyed to the account so a sign-out / account switch never leaks one account's history
// onto another.

extension Notification.Name {
    /// Posted (on an arbitrary thread) whenever `WatchedHistoryIndex.shared` gains entries.
    public static let watchedHistoryIndexDidUpdate = Notification.Name("WatchedHistoryIndexDidUpdate")
}

public actor WatchedHistoryIndex {
    public static let shared = WatchedHistoryIndex(persistenceDirectory: WatchedHistoryIndex.defaultDirectory)

    /// Progress assigned when History lists a video but its tile has no better signal.
    public static let playedFallbackProgress: Double = 1.0

    public struct Page: Sendable {
        public var ids: [String: Double]
        public var next: String?
        public init(ids: [String: Double], next: String?) {
            self.ids = ids
            self.next = next
        }
    }

    public typealias PageFetcher = @Sendable (_ continuation: String?) async throws -> Page

    public struct Snapshot: Sendable {
        public var entries: [String: Double]
        /// No further history pages will be loaded (exhausted or capped).
        public var complete: Bool
        public var pagesLoaded: Int
        /// Entries are older than the TTL (a background refresh may be running).
        public var stale: Bool
    }

    private struct Persisted: Codable {
        var entries: [String: Double]
        var complete: Bool
        var pagesLoaded: Int
        var savedAt: Date
    }

    private var entries: [String: Double] = [:]
    private var ownerKey: String?
    private var loadedAt: Date?
    private var nextToken: String?
    private var pagesLoaded = 0
    private var complete = false
    private var task: Task<Void, Never>?
    private var deepenTask: Task<Void, Never>?

    private let ttl: TimeInterval
    private let maxEntries: Int
    private let maxPages: Int
    private let initialPages: Int
    private let now: () -> Date
    private let persistenceDirectory: URL?

    public init(
        ttl: TimeInterval = 30 * 60,
        maxEntries: Int = 800,
        maxPages: Int = 40,
        initialPages: Int = 3,
        persistenceDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.ttl = ttl
        self.maxEntries = maxEntries
        self.maxPages = maxPages
        self.initialPages = initialPages
        self.persistenceDirectory = persistenceDirectory
        self.now = now
    }

    private static var defaultDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("WatchedHistoryIndex", isDirectory: true)
    }

    // MARK: Reads

    /// Current in-memory (or persisted) view for `ownerKey`; never touches the network.
    public func snapshot(ownerKey: String) -> Snapshot {
        adopt(ownerKey)
        return makeSnapshot()
    }

    /// Progress for one video from the current account's index, if any.
    public func progress(for videoId: String) -> Double? { entries[videoId] }

    /// Every entry of the current account's index (video id -> progress), for bulk filters.
    public func allProgress() -> [String: Double] { entries }

    // MARK: Loading

    /// Makes sure `ownerKey` has an index and returns it.
    ///  - nothing cached: loads the first `initialPages` pages (blocking, coalesced);
    ///  - cached but older than the TTL: returns it now and refreshes the top pages in
    ///    the background (stale-while-revalidate);
    ///  - fresh: returns it as is.
    /// A failed initial load yields an empty snapshot and is retried by the next call.
    public func warm(ownerKey: String, fetch: @escaping PageFetcher) async -> Snapshot {
        adopt(ownerKey)
        let isStale = loadedAt.map { now().timeIntervalSince($0) >= ttl } ?? true
        if entries.isEmpty {
            let t = loadTask(owner: ownerKey, fetch: fetch)
            await t.value
        } else if isStale || (!complete && nextToken == nil) {
            // Stale, or restored from disk mid-deepening with no continuation token.
            _ = loadTask(owner: ownerKey, fetch: fetch)
        }
        return makeSnapshot()
    }

    /// Starts loading further pages in the background (no-op when complete, capped, or
    /// already running). Posts `.watchedHistoryIndexDidUpdate` as entries arrive.
    public func deepenInBackground(ownerKey: String, fetch: @escaping PageFetcher) {
        adopt(ownerKey)
        guard !complete, deepenTask == nil else { return }
        deepenTask = Task<Void, Never> { [weak self] in
            _ = await self?.runDeepen(owner: ownerKey, fetch: fetch)
        }
    }

    /// Awaits any running background work (tests, diagnostics).
    public func waitForIdle() async {
        await task?.value
        await deepenTask?.value
    }

    public func reset() {
        entries = [:]
        loadedAt = nil
        nextToken = nil
        pagesLoaded = 0
        complete = false
        task?.cancel()
        task = nil
        deepenTask?.cancel()
        deepenTask = nil
        if let dir = persistenceDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        ownerKey = nil
    }

    // MARK: Internals

    private func makeSnapshot() -> Snapshot {
        Snapshot(
            entries: entries, complete: complete, pagesLoaded: pagesLoaded,
            stale: loadedAt.map { now().timeIntervalSince($0) >= ttl } ?? true)
    }

    /// Switches to `key`, dropping the previous account's state and loading `key`'s file.
    private func adopt(_ key: String) {
        guard ownerKey != key else { return }
        entries = [:]
        loadedAt = nil
        nextToken = nil
        pagesLoaded = 0
        complete = false
        task?.cancel()
        task = nil
        deepenTask?.cancel()
        deepenTask = nil
        ownerKey = key
        if let p = readPersisted(for: key) {
            entries = p.entries
            complete = p.complete
            pagesLoaded = p.pagesLoaded
            loadedAt = p.savedAt
        }
    }

    /// Coalesces concurrent top-page loads into one task.
    private func loadTask(owner: String, fetch: @escaping PageFetcher) -> Task<Void, Never> {
        if let task { return task }
        let t = Task<Void, Never> { [weak self] in
            _ = await self?.runTopLoad(owner: owner, fetch: fetch)
        }
        task = t
        return t
    }

    private func runTopLoad(owner: String, fetch: PageFetcher) async {
        var fresh: [String: Double] = [:]
        var token: String?
        var pages = 0
        var next: String?
        do {
            while pages < initialPages {
                let page = try await fetch(token)
                pages += 1
                for (k, v) in page.ids { fresh[k] = max(fresh[k] ?? 0, v) }
                next = page.next
                guard let n = page.next else { break }
                token = n
            }
        } catch {
            if fresh.isEmpty {
                finishTask(owner: owner)
                return
            }
        }
        guard ownerKey == owner, !Task.isCancelled else { return }
        let priorComplete = complete
        for (k, v) in fresh { entries[k] = v }
        loadedAt = now()
        if priorComplete {
            // Deeper pages already loaded or capped; only the top was refreshed.
        } else {
            nextToken = next
            pagesLoaded = pages
            complete = next == nil || entries.count >= maxEntries
        }
        persist()
        finishTask(owner: owner)
        NotificationCenter.default.post(name: .watchedHistoryIndexDidUpdate, object: nil)
    }

    private func finishTask(owner: String) {
        if ownerKey == owner { task = nil }
    }

    private func runDeepen(owner: String, fetch: PageFetcher) async {
        // Let a running top load settle first so the continuation token is current.
        await task?.value
        var sinceNotify = 0
        while ownerKey == owner, !complete, !Task.isCancelled {
            guard let token = nextToken else { break }
            guard pagesLoaded < maxPages, entries.count < maxEntries else {
                complete = true
                break
            }
            do {
                let page = try await fetch(token)
                guard ownerKey == owner, !Task.isCancelled else { return }
                for (k, v) in page.ids { entries[k] = max(entries[k] ?? 0, v) }
                pagesLoaded += 1
                nextToken = page.next
                if page.next == nil { complete = true }
                sinceNotify += 1
                if sinceNotify >= 3 {
                    sinceNotify = 0
                    NotificationCenter.default.post(name: .watchedHistoryIndexDidUpdate, object: nil)
                }
            } catch {
                break  // retried on the next channel visit / refresh
            }
        }
        guard ownerKey == owner else { return }
        if pagesLoaded >= maxPages || entries.count >= maxEntries { complete = true }
        deepenTask = nil
        persist()
        // WATCHDIAG
        print("[WATCHDIAG] history deepen finished ids=\(entries.count) pages=\(pagesLoaded) complete=\(complete)")
        NotificationCenter.default.post(name: .watchedHistoryIndexDidUpdate, object: nil)
    }

    // MARK: Persistence

    private func fileURL(for key: String) -> URL? {
        guard let dir = persistenceDirectory else { return nil }
        let safe = String(
            key.unicodeScalars.map { $0.properties.isAlphabetic || ("0"..."9").contains($0) ? Character($0) : "_" })
        return dir.appendingPathComponent("history-\(safe).json")
    }

    private func readPersisted(for key: String) -> Persisted? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(Persisted.self, from: data)
    }

    private func persist() {
        guard let key = ownerKey, let url = fileURL(for: key), !entries.isEmpty else { return }
        let p = Persisted(entries: entries, complete: complete, pagesLoaded: pagesLoaded, savedAt: loadedAt ?? now())
        guard let data = try? JSONEncoder().encode(p) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    // MARK: Merge

    /// Applies `index` to videos: shown remote progress is the larger of what the
    /// response carried and what History says, so a full watch elsewhere always wins.
    nonisolated public static func merge(_ videos: [Video], index: [String: Double]) -> [Video] {
        guard !index.isEmpty else { return videos }
        return videos.map { v in
            guard let p = index[v.id], p > (v.watchProgress ?? 0) else { return v }
            var copy = v
            copy.watchProgress = p
            return copy
        }
    }
}
