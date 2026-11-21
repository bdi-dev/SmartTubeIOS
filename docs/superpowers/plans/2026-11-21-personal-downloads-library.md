# Personal Downloads Library — implementation plan

> Audience: a small model (Haiku) executing step by step. Do ONE task at a time, run its
> verification, then commit. Do not skip ahead, do not redesign, do not add features not listed.
> Personal-use build only (sideloaded, never submitted) — App Store guideline 5.2.3 does not apply.

## Goal
A self-contained Downloads library: Download action on videos → files in app storage →
Downloads screen → playback through the existing AVPlayer pipeline. Metadata keyed by YouTube
`videoId`.

## What already exists (do NOT rewrite from scratch)
Downloading was compiled out in commit `117448c` by wrapping code in `#if ENABLE_DOWNLOADS`.
Old versions of everything are also in git: `git show 117448c^:<path>`.
Files still in the tree (all gated): `VideoDownloadService.swift`, `DownloadStore.swift`,
`DownloadsView.swift`, `DownloadActivityAttributes.swift`, `DownloadLiveActivity.swift`,
`LibraryView.swift` (Downloads chip), `VideoCardView.swift`, `ShortsCardView.swift`,
`PlayerView*.swift`, `RootView.swift`, `SmartTubeApp.swift`, `AppEntry.swift`,
`Smart_TubeApp.swift`, `Info.plist` (commented keys), `DownloadStoreTests.swift`, 2 UI test files.
Local playback already works via `Video.localFileURL` + the fast path in
`PlaybackViewModel+Loading.swift` (this is the AVPlayer pipeline, not the web player).

## Rules (from AGENTS.md — follow exactly)
- Swift 6 strict concurrency. `@MainActor @Observable` view models. No Combine / `@Published` /
  `DispatchQueue` / completion handlers in new code.
- `SmartTubeIOSCore` is Foundation-only (no SwiftUI/UIKit/AVFoundation). `DownloadStore` lives
  there; the downloader (AVFoundation, URLSession background) lives in `SmartTubeIOS`.
- Logging via `os.Logger`; never `print`. No `Task.sleep` in tests; no live network in tests.
- Never edit `project.pbxproj`. New Swift files in synchronized folders are auto-included.
- Commits: `feat(downloads): … ` Conventional Commits.
- `just` is NOT installed on this Mac. Use the raw commands below.

## Commands
Build (iOS):
```bash
xcodebuild build -workspace SmartTube.xcworkspace -scheme SmartTube \
  -destination "platform=iOS Simulator,name=iPhone 17" \
  -derivedDataPath ~/DevTemp/smarttube/derived-data/xcode CODE_SIGNING_ALLOWED=NO -quiet
```
Format check a file: `xcrun swift-format lint --strict --configuration .swift-format <file>`
(`AppSettings.swift` already has 2 pre-existing LineLength errors — ignore those.)
Unit tests: `swift test` currently fails to build on macOS (known, see AGENTS.md). Run package
tests through Xcode instead:
```bash
xcodebuild test -workspace SmartTube.xcworkspace -scheme SmartTube \
  -destination "platform=iOS Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO \
  -only-testing:SmartTubeIOSTests/DownloadStoreTests
```
(If the scheme/test-target name differs, run `xcodebuild -list -workspace SmartTube.xcworkspace`
and use the unit-test target that contains `DownloadStoreTests`.)

---

## Task 1 — Un-gate the code
1. Remove every `#if ENABLE_DOWNLOADS` / matching `#endif` (and any `#else` branch that existed
   only to compile downloads out) from the files in the list above. Keep the code between them.
   Find them: `grep -rn "ENABLE_DOWNLOADS" --include='*.swift' .`
2. In `SmartTubeApp/SmartTubeApp/Info.plist`, un-comment the block containing
   `NSSupportsLiveActivities` and `NSSupportsLiveActivitiesFrequentUpdates`. **Leave
   `NSPhotoLibraryAddUsageDescription` out** (Photos is being removed in Task 3).
3. Build. Fix only compile errors caused by un-gating.
Verify: build succeeds; `grep -rn ENABLE_DOWNLOADS .` returns nothing under `Sources/`/`SmartTubeApp/`.
Commit: `feat(downloads): re-enable downloading for personal build`

## Task 2 — Make the store robust (SmartTubeIOSCore/DownloadStore.swift)
Change `DownloadedVideo`:
- Replace absolute `fileURL: URL` with `fileName: String` (e.g. `"<videoId>.mp4"`). The store
  computes the full URL as `downloadsDirectory/fileName` (absolute paths break when the app
  container path changes after reinstall/update).
- Add `status: Status` (`enum Status: String, Codable, Sendable { case queued, downloading, merging, complete, failed }`),
  `errorMessage: String?`, `progress: Double` (0…1, not persisted-critical).
- Keep `videoId`, `title`, `channelTitle`, `thumbnailURL`, `duration`, `downloadedAt`.
- Decoding must tolerate old manifests: old entries have `fileURL` and no `status`. Use a custom
  `init(from:)`: if `fileURL` present, take its `lastPathComponent` as `fileName` and set
  `status = .complete`.
- `video` computed property sets `localFileURL` from the store-resolved URL; only offer playback
  when `status == .complete`.
Store changes:
- `func upsert(_:)` (replaces `add`), `func setProgress(videoId:progress:)`,
  `func setStatus(videoId:status:error:)`.
- `func finalize(videoId:from tempURL: URL)`: move temp file to `<videoId>.partial` in the
  downloads dir, then `FileManager.replaceItem`/atomic move to `<videoId>.mp4`, THEN set
  `status = .complete`. Never mark complete before the move succeeds.
- `func reconcile()` called from `init`: (a) entries marked `complete` whose file is missing →
  `failed`; (b) entries `queued/downloading/merging` at launch → `failed("Interrupted")`;
  (c) delete stray `*.partial` files.
- Exclude the downloads directory from iCloud backup (`URLResourceValues.isExcludedFromBackup`).
Tests (Swift Testing, in `DownloadStoreTests.swift`, use a temp directory injected into the
store init — add an `init(directory:)` if missing): old-manifest decode, finalize sets complete
only after file exists, reconcile marks missing file failed, reconcile deletes `.partial`.
Verify: DownloadStoreTests pass.
Commit: `feat(downloads): status, relative paths and reconcile in DownloadStore`

## Task 3 — Queue downloader, no Photos (SmartTubeIOS/Services/VideoDownloadService.swift)
Rework the existing service (keep its stream-resolution + merge helpers: `tryDirectDownload`,
`mergeAdaptiveStreams`, `passthroughRemux`, `cdnRequest`):
- Remove all Photos code (`import Photos`, `requestPhotoAddAccess`, `saveToPhotoLibrary`, the
  PHPhotos error handling).
- Replace the single `state` with a queue: `public private(set) var items: [String: DownloadProgress]`
  keyed by videoId (or just read progress from `DownloadStore`), and
  `func enqueue(video: Video)` — ignore if already queued/downloading/complete; otherwise
  `store.upsert(status: .queued)` and append to a FIFO.
- Process at most 2 downloads concurrently (one constant, e.g. `DownloadTuning.maxConcurrent = 2`,
  defined once). Use a `Task`-based worker loop, no DispatchQueue.
- Per item: resolve → download to temp → (merge if adaptive) → `passthroughRemux` (keeps moov
  atom first so AVPlayer streams it) → `store.finalize(videoId:from:)`. Update `setProgress`
  during download and `setStatus(.merging)` during merge. On error: `setStatus(.failed, error)`
  and delete the temp file.
- `func cancel(videoId:)` and `func retry(videoId:)`.
- Keep the Live Activity calls but drive them from the aggregate (e.g. the first active item).
  If this is awkward, remove Live Activity usage from the service for now — it is optional.
Tests: add a protocol seam for "resolve + download" (e.g. `protocol DownloadFetching`) and a fake
in tests to verify: queue ordering, max-concurrency, failure → `failed`, success → `complete`,
duplicate enqueue ignored. No live network.
Verify: build + new tests pass.
Commit: `feat(downloads): queued downloader storing to app storage only`

## Task 4 — Background URLSession
Switch the CDN file download in the service from `URLSession.shared`-style data tasks to a
background `URLSession` (`URLSessionConfiguration.background(withIdentifier:)`, identifier
defined once as a constant). Needs a delegate (`URLSessionDownloadDelegate`) that is
`nonisolated`, forwards progress/completion to the `@MainActor` service, and
`application(_:handleEventsForBackgroundURLSession:completionHandler:)` wired in the app
delegate (find it in `AppEntry.swift`). Background sessions require setting the CDN
`User-Agent` via `URLRequest` headers (already done by `cdnRequest`).
If this proves difficult, STOP and report — do not half-implement; foreground-only downloads
(Task 3) are acceptable for now.
Verify: build; manually start a download in the simulator, background the app, confirm it completes.
Commit: `feat(downloads): background URLSession`

## Task 5 — UI entry points
- Video card long-press menu + Shorts card menu: "Download" already exists (gated before) → now
  calls `enqueue`. Change the label from "Download to Gallery" to "Download"; if already
  downloaded show "Downloaded" disabled; if queued/downloading show "Downloading…".
- TOS player (web player) menu: add a "Download" item that calls `enqueue(video:)`. Find where
  the TOS player's overflow menu is built (`grep -rn "TOSPlayerView" SmartTubeIOS/Sources`).
  If the menu location is unclear, skip and report.
- `DownloadsView`: for each row show thumbnail, title, channel, duration, and by status: progress
  bar (downloading), "Queued", "Merging…", error text + Retry (failed). Tap on `.complete` plays
  through `PlayerRouter`/`PlayerStateStore` with `localFileURL` (AVPlayer, NOT the web player —
  local files must always use the AVPlayer path). Swipe-to-delete calls the store's `remove`
  (also cancels an active download).
- Use `AppSymbol` for symbols and existing accessibility-ID conventions (use whichever the
  neighbouring code in each file uses; do not invent a new scheme).
Verify: build; run in simulator: long-press a video → Download → appears in Library › Downloads
with progress → completes → plays offline (airplane mode).
Commit: `feat(downloads): download actions and Downloads screen states`

## Task 6 — Docs
- Add a short ADR `docs/adr/0012-personal-downloads.md` (use `docs/adr/template.md`): downloads
  re-enabled for personal sideloaded builds only; metadata keyed by videoId; app-storage only;
  not for App Store submission (would need `#if` gating again).
- Update `docs/architecture.md` Downloads mention if present.
Commit: `docs: ADR-0012 personal downloads`

## Out of scope (do not do)
yt-dlp / companion server (a later `DownloadSource` fallback), Photos export, iCloud sync of
downloads, tvOS downloads, subtitles/chapters.

## Definition of done
Build passes; DownloadStore + downloader unit tests pass; manual simulator check from Task 5
works; `git grep ENABLE_DOWNLOADS` is empty.
