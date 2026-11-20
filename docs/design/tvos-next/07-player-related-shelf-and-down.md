# 07 - Related shelf title padding, and Down order during playback

## Goals
1. Titles on the related-videos shelf over the video are padded poorly and hard to read.
2. During playback, pressing Down on the remote should first open the player controls; a second Down (with controls showing) should raise the related shelf.

## Current code (`SmartTubeIOS/Views/Player/MPV/MPVPlayerView.swift`)
- Shelf: `relatedShelf(vm)`, shelf padding 50 pt with `.scrollClipDisabled()`.
- Controls: `vm.controlsVisible`; the bottom row's `.onMoveCommand` (~line 734) opens the shelf on Down. Check what Down does when controls are hidden (it may already open the shelf directly from the surface-level handler near `onMoveCommand` lines ~468/556).
- Remember: `onMoveCommand` does not consume the move; the focus engine still moves focus. Use the same swallow/replay patterns already in this file.

## Plan
1. Inspect a simulator screenshot of the shelf (tile title text over what background, padding between artwork and title, line limit, contrast). Fix per Apple guidance: title below the artwork, readable weight/size, adequate padding, a solid or material backing behind text if it sits over video. Reuse the card styling from `VideoCardView` rather than hand-rolled numbers.
2. Down with controls hidden: show controls only (focus the transport row as it does today when controls appear), do not open the shelf. Down again while controls are visible and focus is on the bottom row: open the shelf. Back order must stay: comments > shelf > controls > exit.
3. Keep the timeline-focus restore behaviour (`lastTransportFocus`) intact; run the existing `TVMPVTimelineFocusUITests` after your change.
4. Add UI tests: Down once shows controls and not the shelf; Down twice shows the shelf.

## Done when
Both behaviours are shown by UI tests, the timeline tests still pass, and you attach before/after screenshots of the shelf.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `docs/design/tvos-styling-guide.md` first: Apple tvOS HIG and standard behaviour beat hard-coded numbers in this plan.
- Never push, never open a PR. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Build/test with your own derived data (`-derivedDataPath ~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned tvOS simulator; do not touch the shared simulator. Unit tests: scheme `SmartTubeIOS-Package`, a tvOS Simulator destination by id. UI tests with XCUIRemote live in `SmartTubeApp/UITests/`.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

