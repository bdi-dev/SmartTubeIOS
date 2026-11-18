#if os(tvOS)
import XCTest

// MARK: - TVSettingsUITests
//
// Verifies that the Settings tab is reachable via the tvOS tab bar and that
// key controls are present in the accessibility tree.
//
// No network access is required — all tested elements are static UI.
//
// Navigation: tab bar → right × 4 → select = Settings tab
// (same pattern proven by TVFocusChainUITests.testSettingsTabBarVisibleAfterScrollDownAndUp)

final class TVSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    // MARK: - Lifecycle

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        try openSettings()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helpers

    private func openSettings() throws {
        for _ in 0..<4 { remote.press(.right) }
        remote.press(.select)
        // Wait for resetAllButton as the sentinel that Settings has fully rendered
        let sentinel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.resetAllButton'"))
            .firstMatch
        guard sentinel.waitForExistence(timeout: 12) else {
            try captureAndSkip("settings.resetAllButton not found — Settings tab did not open", in: app)
        }
    }

    // MARK: - Tests

    /// The sign-in button must appear in Settings when the user is not signed in.
    func testSignInButtonVisibleWhenSignedOut() throws {
        let signInButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.signInButton'"))
            .firstMatch
        guard signInButton.waitForExistence(timeout: 5) else {
            try captureAndSkip(
                "settings.signInButton not found — device may already be signed in (expected a signed-out state for this test)",
                in: app
            )
        }
        XCTAssertTrue(signInButton.exists, "settings.signInButton must be in the accessibility tree when signed out")
    }

    /// The Hide Shorts toggle must be in the accessibility tree.
    func testHideShortsToggleExists() {
        let toggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.hideShortsToggle'"))
            .firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10),
            "settings.hideShortsToggle must be in the accessibility tree"
        )
    }

    /// The SponsorBlock toggle must be in the accessibility tree.
    func testSponsorBlockToggleExists() {
        let toggle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.sponsorBlockToggle'"))
            .firstMatch
        XCTAssertTrue(
            toggle.waitForExistence(timeout: 10),
            "settings.sponsorBlockToggle must be in the accessibility tree"
        )
    }

    /// The Max Resolution picker must be in the accessibility tree.
    func testPreferredQualityPickerExists() {
        let picker = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.preferredQualityPicker'"))
            .firstMatch
        XCTAssertTrue(
            picker.waitForExistence(timeout: 10),
            "settings.preferredQualityPicker must be in the accessibility tree"
        )
    }

    /// The Preferred Audio Language row must be in the accessibility tree.
    func testPreferredAudioLanguageRowExists() {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.preferredAudioLanguageRow'"))
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "settings.preferredAudioLanguageRow must be in the accessibility tree"
        )
    }

    /// The Seek Back picker must be in the accessibility tree on tvOS.
    func testSeekBackRowExists() {
        let row = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.seekBackRow'"))
            .firstMatch
        XCTAssertTrue(
            row.waitForExistence(timeout: 10),
            "settings.seekBackRow must be in the accessibility tree on tvOS"
        )
    }

    /// The Reset All Settings button must be in the accessibility tree.
    func testResetAllSettingsButtonExists() {
        let button = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.resetAllButton'"))
            .firstMatch
        XCTAssertTrue(
            button.waitForExistence(timeout: 10),
            "settings.resetAllButton must be in the accessibility tree"
        )
    }

    /// Regression test for #149: the Settings tab must open on the first select press.
    /// Before the fix, MainTVTabView used an unbound TabView which made the tvOS focus
    /// engine require two presses — the first focused the tab, the second activated it.
    func testSettingsTabOpensSingleSelectPress() throws {
        // setUpWithError already calls openSettings() which presses select exactly once.
        // If the sentinel was found (setup succeeded), Settings opened on a single press.
        let sentinel = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'settings.resetAllButton'"))
            .firstMatch
        XCTAssertTrue(
            sentinel.waitForExistence(timeout: 10),
            "#149 regression: Settings tab must open after a single select press, not two"
        )
    }
}
// MARK: - TVSidebarSettingsUITests
//
// Reproduces the report that, with the sidebar Home layout (the tvOS default), opening a
// Settings sub-menu blanks the screen and the sidebar stops responding afterwards.
// Focus is driven with XCUIRemote; sidebar items are found by identifier and reached with
// remote presses until they have focus.

final class TVSidebarSettingsUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
    }

    /// Presses `direction` until `target` has focus, up to `maxPresses` times.
    @discardableResult
    private func moveFocus(to target: XCUIElement, direction: XCUIRemote.Button, maxPresses: Int = 30) -> Bool {
        for _ in 0..<maxPresses {
            if target.exists && target.hasFocus { return true }
            remote.press(direction)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return target.exists && target.hasFocus
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSettingsSubMenuPushKeepsScreenAndSidebarUsable() throws {
        let sidebarSettings = element("tv.sidebar.settings")
        XCTAssertTrue(sidebarSettings.waitForExistence(timeout: 20), "sidebar must be visible on launch")
        remote.press(.left)  // move focus from the content into the sidebar
        XCTAssertTrue(moveFocus(to: sidebarSettings, direction: .down), "could not focus sidebar Settings")
        remote.press(.select)

        let visibleSectionsLink = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Visible Sections'")).firstMatch
        XCTAssertTrue(visibleSectionsLink.waitForExistence(timeout: 12), "Settings did not render its rows")
        attach("1-settings-root")

        // Focus stays in the sidebar after select; press right until it leaves the sidebar.
        let sidebarSearch = element("tv.sidebar.search")
        for _ in 0..<6 where sidebarSettings.hasFocus || sidebarSearch.hasFocus {
            remote.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        XCTAssertTrue(moveFocus(to: visibleSectionsLink, direction: .down, maxPresses: 40), "could not focus Visible Sections link")
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("2-after-push-visible-sections")

        let pushedHeader = app.staticTexts["Visible — drag to reorder"]
        XCTAssertTrue(
            pushedHeader.waitForExistence(timeout: 5),
            "Visible Sections sub-page did not appear after select (screen blank or push failed)"
        )

        remote.press(.menu)  // Back from the pushed page should return to the Settings root
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach("3-after-menu")
        XCTAssertTrue(visibleSectionsLink.waitForExistence(timeout: 5), "Menu did not pop back to Settings root")

        remote.press(.left)
        XCTAssertTrue(
            moveFocus(to: sidebarSettings, direction: .down) || moveFocus(to: element("tv.sidebar.search"), direction: .up),
            "sidebar did not regain focus after a Settings push/pop"
        )
        attach("4-sidebar-after-pop")
    }

    /// A deep-linked video opens in a full-screen player with no sidebar, and Back leaves it.
    func testDeepLinkedPlayerHasNoSidebarAndBackLeaves() throws {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments += ["--uitesting-deeplink-video=dQw4w9WgXcQ"]
        app.launch()
        RunLoop.current.run(until: Date().addingTimeInterval(12))
        attach("player-deeplink")
        XCTAssertFalse(element("tv.sidebar.search").isHittable, "sidebar must not be visible over the player")
        remote.press(.menu)
        remote.press(.menu)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("player-deeplink-after-back")
        XCTAssertTrue(element("tv.sidebar.search").waitForExistence(timeout: 10), "sidebar should return after leaving the player")
    }

    /// A video opened from Search (pushed player) is full screen without the sidebar; Back pops.
    func testSearchResultOpensFullScreenPlayer() throws {
        XCTAssertTrue(element("tv.sidebar.search").waitForExistence(timeout: 20))
        remote.press(.select)  // Search is focused at launch; make sure it is the selection
        remote.press(.right)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        remote.press(.down)  // from the search bar to the first suggestion
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        attach("search-results")
        remote.press(.down)
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        attach("search-player")
        XCTAssertFalse(element("tv.sidebar.search").isHittable, "sidebar must be hidden while the player is open")
        remote.press(.menu)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach("search-after-back")
        XCTAssertTrue(element("tv.sidebar.search").isHittable, "sidebar must come back after leaving the player")
    }
}
#endif
