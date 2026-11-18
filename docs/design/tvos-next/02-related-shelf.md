# Plan 2 — Related videos shelf over the playing video

## Goal
While a video plays, pressing **Down on the bare video (controls hidden)** raises a horizontal shelf of related videos over the **bottom third** of the screen. The video keeps playing behind, dimmed (scrim ~40-55%). Select plays the card. Back/Up/Menu dismisses the shelf.

Owner decision: *shelf slides up over the video*, not a shrink-to-PiP and not a full-screen list.

## Existing pieces
- `MPVPlayerViewModel.relatedVideos: [Video]` is already filled by `loadNextInfo()` (end-screen fallback exists for signed-out users, so counts may be small, ~4-8). `Video` has id, title, channelTitle, thumbnail, duration.
- `MPVPlayerView.upNextRow(vm)` renders related cards when the video has **ended**; focus target `.related(String)`; `ID.related`. Reuse the card view; do not duplicate.
- `onPlayVideo` / `play(related:)` on the VM already switch the video (per-engine surface fix is in place — commit `9e69054`).
- `surfaceTarget` currently maps Down (`default:` branch) to `vm.showControls()`. Left/Right seek. Up also shows controls.

## Behaviour spec
1. Controls hidden, focus on surface: **Down** opens the shelf (new state `vm.relatedShelfVisible`), not the controls. **Select** and **Up** still show the controls. Left/Right still seek.
2. Controls visible: Down from the transport row (last row) also opens the shelf (so one gesture works either way); controls hide while the shelf is open to avoid two overlays (ask: if it looks bad, keep controls; decide visually and note the choice).
3. Shelf visible: focus goes to the first card (or last-focused card if reopened within the same video). Left/Right move between cards. Select → `vm.play(related:)`. **Back** closes the shelf and returns focus to `.surface` (not exit the player). **Up** from the card row closes the shelf. Auto-hide timer must not hide the shelf; do not auto-dismiss it while the user is navigating, but dismiss after e.g. 12 s of no input (constant in one place).
4. Playback: unaffected (keeps playing). Do **not** pause.
5. Empty `relatedVideos`: Down does nothing visible (or briefly shows the controls). Never show an empty shelf.
6. Shelf header: "Up Next" / "Related" (localised). Cards: thumbnail, 2-line title, channel, duration badge; focused card scales (tvOS `CardButtonStyle`-like) — reuse `upNextRow` styling.
7. Animation: `.move(edge: .bottom).combined(with: .opacity)`, 0.25 s ease-out.
8. When the shelf opens, the dim scrim gradient is bottom-weighted only so the top two thirds of the video stay visible.
9. End-of-video: existing `upNextRow` behaviour stays. The new shelf is a different state; do not show both. If `videoEnded`, use the existing row.
10. Menu/Back handling: the player already uses `.onExitCommand`/Back to hide controls; extend the priority order: shelf → controls → leave player. (Look at how Back is handled in `MPVPlayerView`; owner confirmed Back-hides-controls works — do not regress it.)

## Implementation steps
1. VM: add `relatedShelfVisible`, `openRelatedShelf()`, `closeRelatedShelf()`; make `showControls` close the shelf; guard `holdControls`/auto-hide so they ignore it.
2. View: add `relatedShelf(vm)` overlay in `playerBody` ZStack above the surface, below error overlay. Reuse the card builder from `upNextRow` (extract a `relatedCard(_:)` helper).
3. Focus: reuse `.related(id)`. Add `focusSection()` on the shelf. Update `.onChange(of: focus)` so card focus does not call `showControls()`.
4. `surfaceTarget.onMoveCommand`: `.down` → `vm.openRelatedShelf()` if `!relatedVideos.isEmpty`, else `showControls()`.
5. Update the safety-net `.task` so it knows about the shelf (`focus = first related`).
6. Strings in `Localizable.xcstrings`.
7. Docs: add a line to `docs/design/tvos-mpv-player-plan.md` under "done".

## Edge cases
- Playing next from the shelf: shelf closes, controls hidden, new VM created by existing `.task(id:)`.
- Rotating/app backgrounding: shelf state resets with VM.
- Data arrives late: if the shelf is open and `relatedVideos` was empty, do not open; don't spin.
- Ensure a focused card does not leave the hierarchy mid-update (see the safety-net comment about focus settling on nil).

## Acceptance
Down on bare video opens shelf, video keeps playing, Select plays a card with correct picture/timeline, Back closes shelf only, Left/Right seek still works with shelf closed, no focus loss to nil.

## Tests
Unit-test any pure state logic (shelf open/close rules) if extracted. Verify in Simulator via screenshots; owner verifies on the TV.

## Depends on
Plan 1 (focus memory) — do it first.
