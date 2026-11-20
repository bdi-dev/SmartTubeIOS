# 11 - Hide-watched filters should see progress that arrives late

## Goal
"Hide watched" filters read only the progress that came with the first load (`video.watchProgress`). Progress added later from YouTube History (`WatchedHistoryIndex`) or local playback is shown on cards (via `WatchProgressPolicy.combined`) but the filters ignore it, so videos that show as watched can stay in a "hide watched" list.

## Current code
- Cards: `Views/Browse/VideoCardView.swift` (`effectiveProgress = WatchProgressPolicy.combined(video.watchProgress, historyProgress, localProgress)`).
- Filters: find every use of the hide-watched setting (search for `hideWatched`, and the History exemption #121) in `HomeView.swift`, `BrowseView.swift`, `LibraryView.swift`, `ChannelView.swift`, `SearchView.swift`, `SettingsStore.swift`, `BrowseViewModel.swift`.
- Index: `InnerTubeKit/WatchedHistoryIndex.swift` (`progress(for:)`, `.watchedHistoryIndexDidUpdate`), local store `LocalWatchHistoryStore`.

## Plan
1. Inventory the filters and what each reads; report it.
2. Add one pure helper in `SmartTubeIOSCore` (for example `[Video].removingWatched(threshold:index:local:)`) that applies the same combined-progress rule the cards use, and make every filter call it. One definition of the rule.
3. Views re-filter when `.watchedHistoryIndexDidUpdate` fires (the card already observes it). Avoid layout jumps: do not remove a card the user is focused on or has just played; apply on the next refresh in that case.
4. Keep the History section exempt, as today.
5. Unit tests for the helper: first-load progress, index-only progress, local-only progress, threshold boundary, nil everywhere.

## Done when
Tests pass, tvOS and iOS schemes build, and every filter surface is listed with before/after behaviour.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `AGENTS.md` and `.claude/rules/swift.md` first: Swift 6 strict concurrency, `@MainActor @Observable` view models, `SmartTubeIOSCore` Foundation-only, identifiers from `AccessibilityID`, symbols from `AppSymbol`, no `Task.sleep` or live network in unit tests, fakes at protocol seams.
- Never push, never open a PR, never touch `project.pbxproj`. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Use your own derived data (`~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned simulator (`xcrun simctl clone`), deleted afterwards. Unit tests: scheme `SmartTubeIOS-Package`, a simulator destination by id (the package does not build for macOS: known, unrelated). Other agents edit other files at the same time: touch only the files your plan names.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

