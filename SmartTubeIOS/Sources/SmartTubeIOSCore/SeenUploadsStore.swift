import Foundation

// MARK: - SeenUploadsStore
//
// Remembers which uploads the app has already seen, so a refresh can tell what is *new*.
// The very first check only records a baseline (no alerts), otherwise enabling alerts would
// announce every video already in the feeds. Capped so it cannot grow without bound.

public actor SeenUploadsStore: UserDefaultsBackedStore {

    public static let shared = SeenUploadsStore()

    struct Value: Codable, Sendable {
        var seen: [String] = []
        /// Sources (e.g. "local", "subscriptions") whose first check has already been recorded.
        var baselines: Set<String> = []

        init() {}

        private enum CodingKeys: String, CodingKey { case seen, baselines, hasBaseline }

        /// Tolerant of the earlier shape (`hasBaseline: Bool`, one source): that meant "local".
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            seen = try container.decodeIfPresent([String].self, forKey: .seen) ?? []
            baselines = try container.decodeIfPresent(Set<String>.self, forKey: .baselines) ?? []
            if try container.decodeIfPresent(Bool.self, forKey: .hasBaseline) == true { baselines.insert("local") }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(seen, forKey: .seen)
            try container.encode(baselines, forKey: .baselines)
        }
    }

    static let defaultsKey = "st_seen_uploads"
    /// Oldest ids are dropped once the list exceeds this.
    public static let maxEntries = 1_000

    private var value = Value()
    let defaults: UserDefaults

    private init() {
        defaults = .standard
        if let loaded = Self.loadFrom(.standard) { value = loaded }
    }

    /// Designated initializer for tests (isolated `UserDefaults` suite).
    init(suiteName: String) {
        defaults = UserDefaults(suiteName: suiteName) ?? .standard
        if let loaded = Self.loadFrom(defaults) { value = loaded }
    }

    func encodedValue() -> Value { value }
    func decodeValue(_ decoded: Value) { value = decoded }

    // MARK: Public API

    /// Whether `source`'s first check has been recorded.
    public func hasBaseline(for source: String = SeenUploadsStore.localSource) -> Bool {
        value.baselines.contains(source)
    }

    public static let localSource = "local"
    public static let subscriptionsSource = "subscriptions"

    public func seenIds() -> Set<String> { Set(value.seen) }

    /// Records `ids` as seen (oldest dropped past `maxEntries`) and marks `source`'s baseline as
    /// taken. Ignored when `ids` is empty: an empty feed (nothing followed yet, signed out, or a
    /// failed fetch) must not count as the baseline, or the first real feed would announce
    /// everything already in it.
    public func markSeen(_ ids: [String], source: String = SeenUploadsStore.localSource) {
        guard !ids.isEmpty else { return }
        let existing = Set(value.seen)
        value.seen.append(contentsOf: ids.filter { !existing.contains($0) })
        if value.seen.count > Self.maxEntries {
            value.seen.removeFirst(value.seen.count - Self.maxEntries)
        }
        value.baselines.insert(source)
        persist()
    }

    public func reset() {
        value = Value()
        persist()
    }
}
