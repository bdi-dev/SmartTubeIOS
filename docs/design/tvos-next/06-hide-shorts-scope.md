# 06 - "Hide Shorts" applies to History, never to a channel's Shorts tab

## Goal
The Hide Shorts setting (`store.settings.hideShorts`) must also hide Shorts in the History section. It must NOT hide anything when the user opens the Shorts tab of a channel page.

## Current code
- Setting: `SmartTubeIOS/Services/SettingsStore.swift`; used in `HomeView.swift`, `BrowseView.swift`, `SearchView.swift`, `LibraryView.swift`, `PlaylistView.swift`, `RSSFeedsView.swift`, `ChannelView.swift` (line ~301 filters the All tab; the Shorts tab uses `vm.shorts` unfiltered), `InnerTubeAPI+VideoRenderers.swift`.
- History comes from `BrowseViewModel` `.history` (remote `fetchHistory` merged with `LocalWatchHistoryStore`) and is shown by the Home/Library views.

## Plan
1. Find where each surface applies the filter; list them in your report.
2. Apply the filter to History (remote and local entries, including paging results), using the same `isShort` test the other sections use. Local entries are stored slim: check `isShort` survives (`LocalWatchHistoryStore.record`) and treat entries without it sensibly.
3. Verify the channel page Shorts tab shows Shorts even with the setting on (tvOS `tvShortsGrid(vm.shorts)` and the iOS path). Fix if anything filters there, including any filter applied inside the API parser.
4. Unit tests for the history filtering with the setting on and off.

## Done when
Tests pass and you can state, per surface, whether the setting applies.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `docs/design/tvos-styling-guide.md` first: Apple tvOS HIG and standard behaviour beat hard-coded numbers in this plan.
- Never push, never open a PR. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Build/test with your own derived data (`-derivedDataPath ~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned tvOS simulator; do not touch the shared simulator. Unit tests: scheme `SmartTubeIOS-Package`, a tvOS Simulator destination by id. UI tests with XCUIRemote live in `SmartTubeApp/UITests/`.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

