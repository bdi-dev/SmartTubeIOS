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

    enum Settings {
        static let useTOSPlayerOnIOSToggle = "settings.useTOSPlayerOnIOSToggle"
        static let iCloudUnavailableNote = "settings.iCloudUnavailableNote"
        static let autoDownloadWatchLaterToggle = "settings.autoDownloadWatchLaterToggle"
        static let autoDownloadWiFiOnlyToggle = "settings.autoDownloadWiFiOnlyToggle"
        static let notifyNewUploadsToggle = "settings.notifyNewUploadsToggle"
        static let ytDlpModePicker = "settings.ytDlpModePicker"
        static let ytDlpURLField = "settings.ytDlpURLField"
        static let ytDlpTokenField = "settings.ytDlpTokenField"
        static let ytDlpTestButton = "settings.ytDlpTestButton"
        static let ytDlpTestResult = "settings.ytDlpTestResult"
    }

    enum VideoCard {
        static let playWebButton = "video.card.playWebButton"
        static let playNativeButton = "video.card.playNativeButton"
        static let playStreamButton = "video.card.playStreamButton"
        static let playServerButton = "video.card.playServerButton"
        static let playInMenu = "video.card.playInMenu"
        static let downloadedBadge = "video.card.downloadedBadge"
    }

    enum Root {
        static let offlineBanner = "offline.banner"
    }

    enum Toast {
        static let message = "toast.message"
    }

    enum Player {
        static let openWebPlayerButton = "player.openWebPlayerButton"
        static let moreMenuPlayWebButton = "player.moreMenu.playWebButton"
        static let moreMenuPlayStreamButton = "player.moreMenu.playStreamButton"
        static let moreMenuPlayServerButton = "player.moreMenu.playServerButton"
    }

    enum TOSPlayer {
        static let moreMenuDownloadRow = "tosPlayer.moreMenu.downloadRow"
        static let moreMenuPlayNativeRow = "tosPlayer.moreMenu.playNativeRow"
        static let moreMenuPlayStreamRow = "tosPlayer.moreMenu.playStreamRow"
        static let moreMenuPlayServerRow = "tosPlayer.moreMenu.playServerRow"
    }
}
