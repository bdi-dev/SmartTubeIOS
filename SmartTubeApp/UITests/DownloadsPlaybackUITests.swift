import XCTest

// MARK: - DownloadsPlaybackUITests
//
// Verifies Downloads is its own tab and that
// the empty state is shown when no videos have been downloaded.
//
// A full playback test (tap row → player opens) requires an actual download,
// which is performed by VideoDownloadUITests. The test here validates the
// screen structure only, exercising DownloadsView.
//
// Launch args: --uitesting

final class DownloadsPlaybackUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--uitesting-reset-downloads"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
        app = nil
    }

    // MARK: - Tests

    /// Downloads is its own tab in the tab bar.
    func testDownloadsTabExists() throws {
        XCTAssertTrue(
            app.tabBars.buttons["Downloads"].waitForExistence(timeout: 5),
            "'Downloads' must be present in the tab bar"
        )
    }

    /// Opening the Downloads tab shows the empty state or a list without crashing.
    func testDownloadsTabDoesNotCrash() throws {
        UITestHelpers.tapTab(named: "Downloads", in: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["downloads.emptyState"].waitForExistence(timeout: 5)
                || app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'downloads.videoRow.'"))
                    .firstMatch.waitForExistence(timeout: 2),
            "Downloads tab must show either an empty state or a video list"
        )
        XCTAssertEqual(app.state, .runningForeground)
    }

    // MARK: - Helpers

    private func captureAndSkip(_ message: String, in app: XCUIApplication) throws -> Never {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.lifetime = .keepAlways
        add(attachment)
        throw XCTSkip(message)
    }
}
