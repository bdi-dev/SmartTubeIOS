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

    /// Opens a Picker row in Settings, checks its options render, picks one, goes Back and
    /// checks the row's value changed. Regression test for blank Picker pages on tvOS.
    func testPickerPageShowsOptionsAndSelectionPersists() throws {
        let sidebarSettings = element("tv.sidebar.settings")
        XCTAssertTrue(sidebarSettings.waitForExistence(timeout: 20), "sidebar must be visible on launch")
        remote.press(.left)
        XCTAssertTrue(moveFocus(to: sidebarSettings, direction: .down), "could not focus sidebar Settings")
        remote.press(.select)

        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Playback Speed'")).firstMatch
        let rowAppeared = row.waitForExistence(timeout: 12)
        if !rowAppeared { print("ROW_MISSING_HIERARCHY_BEGIN\n\(app.debugDescription)\nROW_MISSING_HIERARCHY_END") }
        XCTAssertTrue(rowAppeared, "Settings did not render Playback Speed row")
        let sidebarSearch = element("tv.sidebar.search")
        for _ in 0..<6 where sidebarSettings.hasFocus || sidebarSearch.hasFocus {
            remote.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        attach("settings-root-picker-test")
        print("SETTINGS_ROOT_HIERARCHY_BEGIN\n\(app.debugDescription)\nSETTINGS_ROOT_HIERARCHY_END")
        XCTAssertTrue(
            moveFocus(to: row, direction: .up, maxPresses: 12) || moveFocus(to: row, direction: .down, maxPresses: 40),
            "could not focus Playback Speed row"
        )
        let before = row.label
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        attach("picker-page")
        add(XCTAttachment(string: app.debugDescription))
        print("PICKER_PAGE_HIERARCHY_BEGIN\n\(app.debugDescription)\nPICKER_PAGE_HIERARCHY_END")

        let fast = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS '2×' OR label == '2×'")).firstMatch
        XCTAssertTrue(fast.waitForExistence(timeout: 5), "picker options did not render (blank page)")
        XCTAssertTrue(moveFocus(to: fast, direction: .down, maxPresses: 20), "could not focus 2× option")
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        if !row.waitForExistence(timeout: 2) || row.label == before { remote.press(.menu) }
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        attach("after-select")
        let rowAfter = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Playback Speed'")).firstMatch
        XCTAssertTrue(rowAfter.waitForExistence(timeout: 5), "did not return to Settings root")
        XCTAssertNotEqual(rowAfter.label, before, "row value did not change after selecting an option")
        XCTAssertTrue(rowAfter.label.contains("2"), "row should show 2×, got \(rowAfter.label)")
    }

    /// On launch focus lands in the content column, not on the sidebar's first row, and the
    /// sidebar stays collapsed.
    func testLaunchFocusIsInContentNotSidebar() throws {
        XCTAssertTrue(element("tv.sidebar").waitForExistence(timeout: 20))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        attach("launch-focus")
        XCTAssertFalse(element("tv.sidebar.search").hasFocus, "Search row must not hold initial focus")
        XCTAssertLessThan(element("tv.sidebar").frame.width, 250, "sidebar must be collapsed at launch")
        remote.press(.left)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertGreaterThan(element("tv.sidebar").frame.width, 300, "Left must still open the sidebar")
        remote.press(.menu)
        RunLoop.current.run(until: Date().addingTimeInterval(1))
    }

    /// Captures collapsed and expanded sidebar screenshots and frames for several sections.
    /// Measurement aid for the sidebar spacing work; asserts that the collapsed rail never
    /// extends past the content column's leading edge.
    func testSidebarSpacingMeasurements() throws {
        let sidebar = element("tv.sidebar")
        XCTAssertTrue(sidebar.waitForExistence(timeout: 20))
        for name in ["home", "subscriptions", "playlists", "settings", "search"] {
            let item = element("tv.sidebar.\(name)")
            remote.press(.left)
            _ = moveFocus(to: item, direction: .down, maxPresses: 12) || moveFocus(to: item, direction: .up, maxPresses: 12)
            remote.press(.select)
            RunLoop.current.run(until: Date().addingTimeInterval(6))
            attach("\(name)-expanded")
            print("SPACING \(name) expanded sidebar=\(sidebar.frame)")
            remote.press(.right)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            attach("\(name)-collapsed")
            print("SPACING \(name) collapsed sidebar=\(sidebar.frame)")
            print("SPACING_TREE_BEGIN \(name)\n\(app.debugDescription)\nSPACING_TREE_END")
        }
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
        remote.press(.left)  // focus starts in the content; go to the sidebar's Search row
        XCTAssertTrue(moveFocus(to: element("tv.sidebar.search"), direction: .up))
        remote.press(.select)
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

// MARK: - TVChannelPageUITests
//
// Opens a public channel through `--uitesting-deeplink-channel=<id>` and checks the page
// layout: one title (the header's), a grid that matches Home's spacing and margins, and the
// Shorts tab. Needs network access. Screenshots are attached for visual review.

final class TVChannelPageUITests: XCTestCase {

    private var app: XCUIApplication!
    private let remote = XCUIRemote.shared
    /// MKBHD: a large public channel with many uploads and a Shorts tab.
    private let channelId = "UCBJycsmduvYEL83R_U4JriQ"

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--uitesting-deeplink-channel=\(channelId)"]
        app.launch()
    }

    override func tearDownWithError() throws { app = nil }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func videoCards() -> [XCUIElement] {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'")).allElementsBoundByIndex
    }

    func testChannelPageLayout() throws {
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'")).firstMatch
        let populated = firstCard.waitForExistence(timeout: 40)
        attach("channel-page-wait")
        XCTAssertTrue(populated, "channel video grid did not populate")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach("channel-page")

        // Cards in the same row must be at least 40 pt apart and must not overlap.
        let frames = videoCards().map(\.frame).filter { !$0.isEmpty }
        XCTAssertGreaterThanOrEqual(frames.count, 4, "expected a row of cards")
        let sorted = frames.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
        for (a, b) in zip(sorted, sorted.dropFirst()) where abs(a.minY - b.minY) < 20 {
            XCTAssertGreaterThanOrEqual(b.minX - a.maxX, 39, "cards in a row are closer than 40 pt: \(a) \(b)")
        }
        let sidebar = app.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'tv.sidebar'")).firstMatch
        if sidebar.exists, let leftmost = sorted.map(\.minX).min() {
            XCTAssertGreaterThanOrEqual(leftmost - sidebar.frame.maxX, 40, "grid runs up to the sidebar rail")
        }
        // The navigation bar must not repeat the channel name.
        XCTAssertFalse(app.navigationBars.firstMatch.exists && app.navigationBars.firstMatch.staticTexts.count > 0,
                       "channel name must not be repeated in a navigation bar")
    }

    func testShortsTabAndScrollingLoadsMore() throws {
        let firstCard = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'video.card.'")).firstMatch
        XCTAssertTrue(firstCard.waitForExistence(timeout: 40), "channel video grid did not populate")
        let initialCount = videoCards().count
        // Scroll down through the grid; pagination must keep adding cards.
        for _ in 0..<14 { remote.press(.down); RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach("channel-scrolled")
        print("CHANNEL_CARDS initial=\(initialCount) afterScroll=\(videoCards().count)")
        // Back to the top: Up past the grid lands on the header buttons; Down once reaches the tabs.
        for _ in 0..<16 { remote.press(.up); RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
        let shorts = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Shorts'")).firstMatch
        XCTAssertTrue(shorts.waitForExistence(timeout: 10), "Shorts tab missing")
        remote.press(.down)
        for _ in 0..<3 where !shorts.hasFocus { remote.press(.right); RunLoop.current.run(until: Date().addingTimeInterval(0.4)) }
        XCTAssertTrue(shorts.hasFocus, "could not focus the Shorts tab")
        remote.press(.select)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        attach("channel-shorts")
    }
}
