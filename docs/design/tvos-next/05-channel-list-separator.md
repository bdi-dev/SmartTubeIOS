# 05 - Separator between frequent channels and A-Z

## Goal
The Channels list leads with up to 15 frequently/recently watched channels (`ChannelRanking.ranked`, commit 02764e3), then the rest A-Z. Make the boundary visible.

## Current code
- `SmartTubeIOSCore/ChannelRanking.swift` returns one flat array, so the view cannot tell where the top group ends.
- `SmartTubeIOSCore/BrowseViewModel.swift` `promoteFrequentChannels()` stores the result in `subscribedChannels`.
- `SmartTubeIOS/Views/Channel/ChannelListView.swift` (tvOS: `List` of Button rows).

## Plan
1. Add `ChannelRanking.split(...) -> (frequent: [Channel], rest: [Channel])` (keep `ranked` as a wrapper). Store `frequentChannelCount` (or two arrays) on `BrowseViewModel`, reset to 0 when the list reloads or ranking finds nothing.
2. `ChannelListView` takes the frequent group and rest. Render two `Section`s with small headers ("Frequent", "All channels") in the standard tvOS list header style. No header or separator when the frequent group is empty.
3. Headers must not take focus and must not break up/down focus movement.
4. Unit test the split; add a UI test checking both headers exist when history exists, if feasible with the fixtures.

## Done when
Tests pass, a simulator screenshot (or UI-test assertion) shows the separator, and the avatar cache/scroll behaviour is unchanged.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `docs/design/tvos-styling-guide.md` first: Apple tvOS HIG and standard behaviour beat hard-coded numbers in this plan.
- Never push, never open a PR. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Build/test with your own derived data (`-derivedDataPath ~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned tvOS simulator; do not touch the shared simulator. Unit tests: scheme `SmartTubeIOS-Package`, a tvOS Simulator destination by id. UI tests with XCUIRemote live in `SmartTubeApp/UITests/`.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

