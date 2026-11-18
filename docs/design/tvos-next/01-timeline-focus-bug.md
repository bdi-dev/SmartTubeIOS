# Plan 1 — Timeline ↔ transport-row focus bug

## Problem (owner report)
In the player controls, press Up from a transport button into the timeline (scrubber), then press Down. Focus visibly lands on **+30 (skip forward)** and then **always jumps to Pause/Play**. Required: focus returns to **the exact button the user left** (previous, −10, play, +30, next, and also the right-side menus: captions, speed, quality, audio, chapters if they are in the same row).

## Where the code is
`SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/MPV/MPVPlayerView.swift`
- `controlsOverlay` — scrubber and transport row are each `.focusSection()`; `.defaultFocus($focus, .playPause)`.
- `scrubber(_:)` — `.onMoveCommand`: `.down` calls `vm.commitScrub()` then `focus = .playPause` (hard-coded).
- `body` `.onChange(of: focus)` — logs `[focus] old → new` at debug level (category `mpvViewLog`) and calls `vm.showControls()` on any non-nil, non-surface change.
- `body` `.task(id: vm.controlsVisible)` — after 600 ms, if `focus == nil`, forces `focus = .playPause`.
- `FocusTarget` enum (line ~38).

## Likely root cause (verify first, do not assume)
`onMoveCommand` does **not** consume the move. The focus engine also performs its own downward move from the wide scrubber to the geometrically nearest focusable in the transport row (observed: +30). Our manual `focus = .playPause` then fights it, and/or the 600 ms safety-net task and `.defaultFocus` snap it to Play. Result: flash on +30, then Play.

**Step 0 (diagnose):** run in Simulator with `--uitesting-keep-controls`, move Up from +30, press Down, and read the `[focus]` debug lines (Console / `xcrun simctl spawn booted log stream --predicate 'subsystem == "..."'` or the existing logger category). Record the sequence in the PR/commit message. Confirm which of the two (engine move vs. our assignment vs. safety net) produces each transition.

## Design
1. Add `@State private var lastTransportFocus: FocusTarget = .playPause`.
2. Record it: in `.onChange(of: focus)`, when `newFocus` is one of the transport-row targets (`previous, seekBack, playPause, seekForward, next, captions, speed, quality, audio, chapters`), store it. Do **not** record scrubber/surface/related/skip/error.
3. When the user presses **Up** from the transport row into the scrubber, `lastTransportFocus` already holds the origin (it was the last transport focus). Do not overwrite it while on the scrubber.
4. Scrubber `.down`: `vm.commitScrub()`, then restore focus to `lastTransportFocus`, **after** the engine's own move has settled. Preferred approaches, in order — try 4a first, fall back to 4b:
   - **4a (engine-driven, no manual assignment):** give the transport row `.focusSection()` plus a `prefersDefaultFocus`/`.defaultFocus($focus, lastTransportFocus)` that reads the remembered value, and use `.focusScope` if needed, so the engine itself enters the section at the remembered button. Remove the hard-coded `focus = .playPause` and delete the scrubber `.down` case (let the engine move).
   - **4b (manual):** keep `.down` handler but set focus in a main-actor task after one run-loop turn (`Task { @MainActor in await Task.yield(); focus = lastTransportFocus }`), and cancel/skip the 600 ms safety net while a restore is pending (e.g. `@State restoring: Bool`).
5. Fix the safety net: `focus = vm.controlsVisible ? .playPause : ...` must use `lastTransportFocus` instead of `.playPause` when controls are visible and a value was remembered, otherwise it re-introduces the bug whenever focus is transiently nil.
6. Reset `lastTransportFocus = .playPause` whenever the controls are freshly shown from hidden (so the first visit still defaults to Play), i.e. in `.onChange(of: vm.controlsVisible)` when it becomes `true`.
7. Buttons that appear/disappear (`previous`, `next` depend on `vm.canPlayPrevious/canPlayNext`; `audio`/`chapters` depend on data): if `lastTransportFocus` is no longer present (e.g. next video has no Previous), fall back to `.playPause`. Validate by checking the same booleans used to render the buttons.
8. Related interaction: plan 2 adds focus targets below the controls. Keep `lastTransportFocus` logic generic so Down-from-transport into the related shelf, and Up back, can reuse it.

## Acceptance criteria
- From each transport button: Up → scrubber (bar grows, focused), Down → returns to that same button, **no intermediate focus on +30**, no later jump to Play. Verify for at least: previous, −10, Play, +30, next, quality menu.
- Left/Right on the scrubber still scrubs; Select still commits.
- Controls auto-hide still works; after re-show, focus starts on Play.
- Opening a menu (quality etc.) and closing it still keeps controls up (the `holdControls` logic must not break).
- No new focus warnings in the log.

## Tests
- Unit: if the remembered-focus logic is extracted into a tiny pure helper (e.g. `TransportFocusMemory` with `record(_:)`, `restoreTarget(available:)`), unit-test it (fallback when the button vanished).
- UI test for Simulator is optional (needs Xcode project changes — skip, owner does device check).

## Owner device checklist
Up from +30 then Down → lands on +30. Same from −10 and Quality. First show of controls still lands on Play.

## Out of scope
Changing scrub step sizes, visual redesign of the bar.
