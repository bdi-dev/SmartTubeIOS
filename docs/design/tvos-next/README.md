# tvOS next features — plan index

Plans for Luna / Haiku. **Do not implement from this index; each plan is self-contained.**
Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split` (fork `bdi-dev/SmartTubeIOS`).
**Never open PRs to `milika/SmartTubeIOS`.** Push only to `origin` when the owner says so.

| # | Plan | Size | Order |
|---|------|------|-------|
| 1 | [01-timeline-focus-bug.md](01-timeline-focus-bug.md) | small | do first, independent |
| 2 | [02-related-shelf.md](02-related-shelf.md) | medium | after 1 (shares focus code) |
| 3 | [03-comments-panel.md](03-comments-panel.md) | medium | after 2 (shares layout/state) |
| 4 | [04-home-rework.md](04-home-rework.md) | large | independent, can run in parallel with 2-3 |

## Shared facts

- Player: `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/MPV/MPVPlayerView.swift` (SwiftUI, `FocusTarget` enum, `@FocusState focus`), view model `MPVPlayerViewModel.swift` (`controlsVisible`, `showControls(autoHide:)`, `hideControls()`, `holdControls`, `relatedVideos`, `chapters`).
- Plans 1-3 all edit `MPVPlayerView.swift`. **Run them sequentially, not in parallel, or on separate branches merged carefully.**
- Build/run/test recipes: Simulator build with scheme `Smart Tube` (tvOS), workspace `SmartTubeApp/SmartTube.xcworkspace`. Real Apple TV install via CLI is documented in the owner's memory file `apple-tv-device-install.md` (build with signing overrides, `devicectl device install app`, `devicectl device process launch`). Use `--uitesting-keep-controls` so controls do not auto-hide while testing in the Simulator (tool latency is ~4 s per call).
- The build always ends with a Crashlytics script error (no real `GoogleService-Info.plist`); Swift errors start with a file path. The `.app` is still produced.
- Existing unit tests: `xcodebuild test -scheme SmartTubeIOS-Package` from `SmartTubeIOS/SmartTubeIOS` on a tvOS simulator; ~6 failures are pre-existing upstream (Keychain, NowPlaying, ...).
- Real-device verification is the owner's job: finish each plan with a short checklist for them.
- Localisation: all user-visible strings use `Text("...", bundle: .module)` and need entries in `SmartTubeIOS/Localizable.xcstrings`.
- Commit style: small commits per plan, trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` only if Claude wrote it.

## Owner decisions (from interview)

- Home: sidebar + content grid; plain grid (no Continue watching); History and Playlists as separate sidebar items; follows system appearance.
- Comments: right-side panel, video shrinks left and keeps playing.
- Related: shelf slides up over bottom third, video dimmed but playing.
- Timeline bug: Down from the timeline returns to the exact button the user came from.
