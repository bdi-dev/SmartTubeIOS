/// Accessibility identifiers shared by the views and the UI tests.
///
/// UI tests match these strings exactly, so every value must stay byte-identical to the literal it
/// replaces. Add an id here only when a view uses it; reuse an existing id rather than adding a
/// near-duplicate.
enum AccessibilityID {
    enum Downloads {
        static let enableToggle = "downloads.enableToggle"
        static let cellularToggle = "downloads.cellularToggle"
        static let storageSummary = "downloads.storageSummary"
        static let lowStorageWarning = "downloads.lowStorageWarning"

        static func share(_ videoId: String) -> String { "downloads.share.\(videoId)" }
        static func status(_ videoId: String) -> String { "downloads.status.\(videoId)" }
        static func progress(_ videoId: String) -> String { "downloads.progress.\(videoId)" }
        static func percent(_ videoId: String) -> String { "downloads.percent.\(videoId)" }
        static func retry(_ videoId: String) -> String { "downloads.retry.\(videoId)" }
        static func audioBadge(_ videoId: String) -> String { "downloads.audioBadge.\(videoId)" }
    }
}
