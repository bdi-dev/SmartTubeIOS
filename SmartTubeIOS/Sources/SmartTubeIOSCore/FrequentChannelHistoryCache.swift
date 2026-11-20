import Foundation

// MARK: - HistoryChannelWatch

/// One watched video's channel signal, as read from the account's YouTube History.
public struct HistoryChannelWatch: Codable, Sendable, Equatable {
    public var videoId: String
    public var channelId: String?
    public var channelTitle: String

    public init(videoId: String, channelId: String?, channelTitle: String) {
        self.videoId = videoId
        self.channelId = channelId
        self.channelTitle = channelTitle
    }
}

// MARK: - FrequentChannelHistoryCache
//
// Caches the ordered History triples behind the Channels "Frequent" ranking, so opening the
// Channels list does not re-read six history pages each time. Keyed by account owner (the same
// key `WatchedHistoryIndex` uses) so one account's history never ranks another's channels.
// Served from memory, persisted to Caches per owner, and treated as stale after `ttl`.
// The cache holds only remote History; local plays are read fresh on every ranking.

public actor FrequentChannelHistoryCache {
    public static let shared = FrequentChannelHistoryCache(
        directory: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FrequentChannelHistory", isDirectory: true))

    public struct Snapshot: Sendable, Equatable {
        public var watches: [HistoryChannelWatch]
        /// True when nothing is cached, or the entries are older than the TTL.
        public var stale: Bool
    }

    private struct Persisted: Codable {
        var watches: [HistoryChannelWatch]
        var savedAt: Date
    }

    private var ownerKey: String?
    private var watches: [HistoryChannelWatch] = []
    private var savedAt: Date?

    private let ttl: TimeInterval
    private let directory: URL?
    private let now: @Sendable () -> Date

    public init(
        ttl: TimeInterval = 15 * 60,
        directory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.ttl = ttl
        self.directory = directory
        self.now = now
    }

    // MARK: Reads and writes

    /// The cached watches for `ownerKey` (possibly empty) and whether they are stale.
    /// Never touches the network.
    public func snapshot(ownerKey key: String) -> Snapshot {
        adopt(key)
        let stale = savedAt.map { now().timeIntervalSince($0) >= ttl } ?? true
        return Snapshot(watches: watches, stale: stale)
    }

    /// Replaces the cached watches for `ownerKey`. An empty list is not stored, so a failed
    /// history read never wipes a good cache.
    public func store(_ newWatches: [HistoryChannelWatch], ownerKey key: String) {
        adopt(key)
        guard !newWatches.isEmpty else { return }
        watches = newWatches
        savedAt = now()
        persist()
    }

    /// Drops every owner's cached history (sign-out).
    public func reset() {
        watches = []
        savedAt = nil
        ownerKey = nil
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    // MARK: Internals

    /// Switches to `key`, dropping the previous owner's entries and loading `key`'s file.
    private func adopt(_ key: String) {
        guard ownerKey != key else { return }
        ownerKey = key
        watches = []
        savedAt = nil
        if let persisted = readPersisted(for: key) {
            watches = persisted.watches
            savedAt = persisted.savedAt
        }
    }

    private func fileURL(for key: String) -> URL? {
        guard let directory else { return nil }
        let safe = String(
            key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" })
        return directory.appendingPathComponent("history-\(safe).json")
    }

    private func readPersisted(for key: String) -> Persisted? {
        guard let url = fileURL(for: key), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Persisted.self, from: data)
    }

    private func persist() {
        guard let key = ownerKey, let url = fileURL(for: key), let savedAt else { return }
        guard let data = try? JSONEncoder().encode(Persisted(watches: watches, savedAt: savedAt)) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
