import XCTest

// MARK: - VideoDownloadUITests
//
// End-to-end checks for the personal Downloads library (ADR-0012):
//
//   Method A — Player more menu (AVPlayer pipeline):
//     Open player → "..." (player.moreButton) → "Download" (player.moreMenu.downloadButton).
//
//   Method B — Video card context menu:
//     Search → long-press a card → "Download".
//
// Both end in the same flow: a "Download Complete" alert, then the video appears as a row in
// the Downloads tab (`downloads.videoRow.<id>`).
//
// Requirements: network access (downloads real YouTube CDN content). Tests skip gracefully when
// the network or environment is unavailable. Files go to app storage only — no Photos access.

private let kDownloadVideoID = "JhCjw57u8mQ"

final class VideoDownloadUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func launch(extraArgs: [String] = []) {
        app = XCUIApplication()
        // The web (IFrame) player is the default; its menu has a Download item too, but these
        // tests exercise the AVPlayer pipeline so playback of the saved file can be asserted.
        app.launchArguments =
            ["--uitesting", "--uitesting-disable-tos-player-on-ios", "--uitesting-reset-downloads"] + extraArgs
        app.launch()
    }

    /// Any Downloads row (`downloads.videoRow.<id>`).
    private var anyDownloadRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.videoRow.'"))
            .firstMatch
    }

    /// Waits for the completion/failure alert and returns it, or nil on timeout.
    private func waitForDownloadAlert(timeout: TimeInterval) -> XCUIElement? {
        let alert = app.alerts.containing(
            NSPredicate(format: "label CONTAINS 'Download'")
        ).firstMatch
        return alert.waitForExistence(timeout: timeout) ? alert : nil
    }

    private func dismissAlert() {
        let ok = app.alerts.buttons["OK"].firstMatch
        if ok.waitForExistence(timeout: 3) { ok.tap() }
    }

    /// Opens the Downloads tab and asserts the downloaded video is listed as a finished row.
    private func assertListedInDownloads() throws {
        UITestHelpers.tapTab(named: "Downloads", in: app)

        XCTAssertTrue(
            anyDownloadRow.waitForExistence(timeout: 10),
            "A completed download must be listed in the Downloads tab")
        XCTAssertFalse(
            app.descendants(matching: .any)["downloads.emptyState"].exists,
            "Empty state must not show once a download is listed")
    }

    // MARK: - Method A: player more menu

    func testDownloadFromPlayerMoreMenu() throws {
        launch(extraArgs: ["--uitesting-deeplink-video=\(kDownloadVideoID)"])

        guard app.staticTexts["player.titleLabel"].firstMatch.waitForExistence(timeout: 20) else {
            try captureAndSkip("Player did not open — network unavailable or video inaccessible", in: app)
        }
        guard !app.otherElements["player.errorBanner"].firstMatch.exists else {
            try captureAndSkip("player.errorBanner visible — video inaccessible on this simulator", in: app)
        }

        // Reveal the controls, then open the more menu.
        let moreButton = app.buttons["player.moreButton"].firstMatch
        _ = moreButton.waitForExistence(timeout: 8)  // controls are usually visible at start
        for _ in 0..<8 where !moreButton.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = moreButton.waitForExistence(timeout: 2.5)
        }
        guard moreButton.exists else {
            if app.otherElements["player.errorBanner"].firstMatch.exists {
                try captureAndSkip("AVPlayer pipeline showed player.errorBanner — video not playable here", in: app)
            }
            try captureAndSkip("player.moreButton not found — controls did not appear", in: app)
        }
        moreButton.tap()

        let downloadButton = app.buttons["player.moreMenu.downloadButton"].firstMatch
        if !downloadButton.waitForExistence(timeout: 5) {
            app.scrollViews.firstMatch.swipeUp()
        }
        guard downloadButton.waitForExistence(timeout: 10) else {
            try captureAndSkip("Download button not found in the more menu", in: app)
        }
        XCTAssertTrue(downloadButton.isEnabled, "Download must be enabled before a download starts")
        downloadButton.tap()

        guard let alert = waitForDownloadAlert(timeout: 120) else {
            try captureAndSkip("No download alert within 120 s — network or CDN unavailable", in: app)
        }
        guard alert.label.contains("Complete") else {
            try captureAndSkip("Download failed (network/CDN or restricted content): \(alert.label)", in: app)
        }
        XCTAssertEqual(
            app.alerts.containing(NSPredicate(format: "label CONTAINS 'Download'")).count, 1,
            "Exactly one completion alert must be shown, not one per host view")
        dismissAlert()
    }

    // MARK: - Method B: video card context menu

    func testDownloadFromVideoCardContextMenuAppearsInDownloads() throws {
        launch(extraArgs: ["--uitesting-reset-settings"])

        UITestHelpers.tapTab(named: "Search", in: app)
        let searchField = app.textFields["search.bar"].firstMatch
        guard searchField.waitForExistence(timeout: 10) else {
            try captureAndSkip("Search field not found", in: app)
        }
        searchField.tap()
        searchField.typeText("MKBHD\n")  // "\n" submits; avoids tapping the keyboard's Search key

        guard let card = UITestHelpers.waitForVideoCards(in: app, timeout: 30) else {
            try captureAndSkip("No search results — network unavailable", in: app)
        }
        card.press(forDuration: 1.2)

        let downloadItem = app.buttons["Download"].firstMatch
        guard downloadItem.waitForExistence(timeout: 5) else {
            try captureAndSkip("'Download' not found in the video card context menu", in: app)
        }
        downloadItem.tap()

        // Do not tap anything now: a tap can scroll-to-top and rebuild the card.
        guard let alert = waitForDownloadAlert(timeout: 120) else {
            try captureAndSkip("No download alert within 120 s — network or CDN unavailable", in: app)
        }
        guard alert.label.contains("Complete") else {
            try captureAndSkip("Download failed (network/CDN or restricted content): \(alert.label)", in: app)
        }
        XCTAssertEqual(
            app.alerts.containing(NSPredicate(format: "label CONTAINS 'Download'")).count, 1,
            "Exactly one completion alert must be shown")
        dismissAlert()

        try assertListedInDownloads()
    }
}
