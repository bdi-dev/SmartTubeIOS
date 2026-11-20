# 10 - Cache the history read behind "Frequent channels"

## Goal
`BrowseViewModel.promoteFrequentChannels()` reads six pages of YouTube history on every open of the Channels list (about six requests). Cache the derived ranking signal so repeat visits are instant and cheap, without letting it go stale for long.

## Current code
- `SmartTubeIOSCore/BrowseViewModel.swift` `promoteFrequentChannels()`, `SmartTubeIOSCore/ChannelRanking.swift` (`split`, `ranked`), tests in `ChannelRankingTests`.
- Reference for a persisted, account-keyed, TTL'd cache: `InnerTubeKit/WatchedHistoryIndex.swift` (owner key, disk persistence, 30-minute TTL, reset on sign-out).

## Plan
1. Introduce a small cache (an actor or `@MainActor` store in `SmartTubeIOSCore`, Foundation only) holding the ordered list of watched `(videoId, channelId, channelTitle)` triples from history, keyed by account (use the same owner key as `WatchedHistoryIndex`), with a 15-minute TTL and in-memory plus on-disk persistence under Caches. Reset on sign-out (find where `WatchedHistoryIndex.reset()` is called and do the same).
2. `promoteFrequentChannels()` uses the cache first. If fresh, rank immediately with no network. If stale or empty, rank from the stale data right away (so the list does not jump later), then refresh in the background and re-rank only if the top group changed.
3. Keep the channel-name fallback and the local-only plays logic. Do not change `ChannelRanking` semantics.
4. Pure-logic unit tests with an injected clock and fake fetcher: fresh hit does not fetch; stale hit returns stale then refreshes; sign-out clears; ranking is unchanged when data is equal.

## Done when
Tests pass, the tvOS and iOS schemes build, and the number of history requests per Channels open (fresh vs cold) is stated from a test, not a guess.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `AGENTS.md` and `.claude/rules/swift.md` first: Swift 6 strict concurrency, `@MainActor @Observable` view models, `SmartTubeIOSCore` Foundation-only, identifiers from `AccessibilityID`, symbols from `AppSymbol`, no `Task.sleep` or live network in unit tests, fakes at protocol seams.
- Never push, never open a PR, never touch `project.pbxproj`. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Use your own derived data (`~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned simulator (`xcrun simctl clone`), deleted afterwards. Unit tests: scheme `SmartTubeIOS-Package`, a simulator destination by id (the package does not build for macOS: known, unrelated). Other agents edit other files at the same time: touch only the files your plan names.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

