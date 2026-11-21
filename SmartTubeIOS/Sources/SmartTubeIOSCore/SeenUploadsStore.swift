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
        var hasBaseline = false
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

    public var hasBaseline: Bool { value.hasBaseline }

    public func seenIds() -> Set<String> { Set(value.seen) }

    /// Records `ids` as seen (oldest dropped past `maxEntries`) and marks the baseline as taken.
    /// Ignored when `ids` is empty.
    public func markSeen(_ ids: [String]) {
        // An empty feed (nothing followed yet, or a failed fetch) must not count as the baseline,
        // or the first real feed would announce everything already in it.
        guard !ids.isEmpty else { return }
        let existing = Set(value.seen)
        value.seen.append(contentsOf: ids.filter { !existing.contains($0) })
        if value.seen.count > Self.maxEntries {
            value.seen.removeFirst(value.seen.count - Self.maxEntries)
        }
        value.hasBaseline = true
        persist()
    }

    public func reset() {
        value = Value()
        persist()
    }
}
