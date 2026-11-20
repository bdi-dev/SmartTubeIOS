# 12 - iOS verification and hardening of the shared channel changes

## Goal
Most tvOS work landed in shared code. None of it has been run on iOS. Verify, and fix what is wrong, without adding features.

## Scope
1. **Channel Shorts fetch.** `InnerTubeAPI.fetchChannelShorts` (`InnerTubeKit/InnerTubeAPI+Channel.swift`) uses the TV client (`postTV`, browse `VLUUSH<id>`). Check its behaviour with no auth token, with a token only, and with a web session (SAPISID). Make sure a failure or an empty result falls back to the existing Home-shelf Shorts, never throws into the channel screen, and logs via `os.Logger` for new code. Unit-test the no-token and failure paths with fakes at the `InnerTubeAPIProtocol` seam (`ChannelViewModel` in `SmartTubeIOSCore/SearchViewModel.swift`).
2. **Channel list on iOS.** `Views/Channel/ChannelListView.swift` iOS branch (LazyVStack with "Frequent" and "All channels" headers) and `CachedAvatarImage`. Run it in an iOS simulator if you can seed local subscriptions (`LocalSubscriptionStore`); otherwise review the code for layout, Dynamic Type, VoiceOver headers (header trait) and safe-area behaviour, and fix problems found.
3. **Channel Shorts tab empty state** (`channel.noShorts`) on iOS: confirm it renders and is accessible.
4. **Auth plumbing.** `SharedAuthSession` and the SAPISID hand-off: confirm the iOS app (`SmartTubeIOS/Sources/SmartTubeIOS/SmartTubeApp.swift`) sets the SAPISID so channel pages use the WEB path with per-viewer progress, and that `usesTVChannelVideos` is false there.
5. Report, per item: what you ran, what you only read, and any defect fixed (with a test).

## Done when
Tests pass, the iOS scheme builds for a simulator, and the report separates verified-by-running from verified-by-reading.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `AGENTS.md` and `.claude/rules/swift.md` first: Swift 6 strict concurrency, `@MainActor @Observable` view models, `SmartTubeIOSCore` Foundation-only, identifiers from `AccessibilityID`, symbols from `AppSymbol`, no `Task.sleep` or live network in unit tests, fakes at protocol seams.
- Never push, never open a PR, never touch `project.pbxproj`. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Use your own derived data (`~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned simulator (`xcrun simctl clone`), deleted afterwards. Unit tests: scheme `SmartTubeIOS-Package`, a simulator destination by id (the package does not build for macOS: known, unrelated). Other agents edit other files at the same time: touch only the files your plan names.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

