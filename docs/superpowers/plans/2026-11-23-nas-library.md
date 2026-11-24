# NAS library: shared downloads, keep flag, "Available on NAS" — implementation plan

> Audience: a small model (Haiku) executing step by step. Do ONE task at a time, run its
> verification, then commit. Do not skip ahead, do not redesign, do not add features not listed.
> Personal-use build only (sideloaded, never submitted).
> Revised after an independent review against the code (see "Review changes" at the end).

## Goal
Stop the NAS (yt-dlp companion server) from re-fetching a video it already has, let every device
see what the NAS holds but the device does not, and let the user keep or delete NAS copies from
that list.

## Decisions (approved)
1. **Keep by default.** Every download that goes through the server is kept. The server default
   is `keep: true`; the app does not send it for normal downloads.
2. **No upload from device.** A device download made by its own extractor never reaches the NAS.
   There is no `PUT /v1/files/<id>` upload endpoint. The server-side skip will always be quicker
   than extracting again.
3. **Storage.** Kept files have **no cap**. Unkept files are capped at **20 GB total**; when the
   cap is exceeded, evict unkept files oldest-first (by `downloadedAt`). This **replaces** the
   24-hour age sweep (confirmed).
4. **Branch.** All work is on `feat/tvos-mpv-extractor-split`. Do not branch from `master`.
5. **Lazy loading with a keyset cursor.** The NAS library list is loaded one page at a time. The
   cursor is keyed on `(downloadedAt, videoId)`, not an offset, so new downloads do not shift pages.
6. **Row actions on "Available on NAS".** Swipe right (leading edge) = **Delete from NAS**, with
   full swipe enabled (the SwiftUI default). **No confirmation dialog.** Swipe left (trailing edge)
   = **Keep / Unkeep**. Tap = download to this device.
7. **Streaming sends `keep: false`.** "Play from yt-dlp Server" is a one-off view, not a download,
   so those files are unkept and subject to the 20 GB cap.
8. **Fallback becomes server-first when the server is configured.** The probe adds up to 5 seconds
   when the NAS is off or asleep. This is accepted.

## Rules (from AGENTS.md — follow exactly)
- Swift 6 strict concurrency. `@MainActor @Observable` view models. No Combine / `@Published` /
  `DispatchQueue` / completion handlers in new code.
- `SmartTubeIOSCore` is Foundation-only. Platform code (SwiftUI, URLSession background) stays in
  `SmartTubeIOS`.
- Logging via `os.Logger`; never `print`. Server logs: stderr only, never tokens.
- No `Task.sleep` in tests; no live network in tests. Fakes at protocol seams
  (`YtDlpServerClient`).
- Never edit `project.pbxproj`. Do not add UI-test files (they need Xcode).
- **Accessibility identifiers:** there is no `AccessibilityID` type in the code today, despite
  AGENTS.md. Follow the existing literal convention in `DownloadsView.swift`
  (`downloads.enableToggle`, `downloads.videoRow.<id>`): new ids are `downloads.nas.section`,
  `downloads.nas.row.<id>`, `downloads.nas.keep.<id>`, `downloads.nas.delete.<id>`. Do not invent
  an `AccessibilityID` type.
- **Symbols:** `AppSymbol` (`Views/ViewHelpers.swift`) has no pin symbol. Task 3.3 adds
  `AppSymbol.pin`. Use `AppSymbol` for every icon.
- Links inside this plan use backticks, not relative markdown links, because the repo's
  `doc-links` check resolves links relative to this folder.
- Commits: Conventional Commits, e.g. `feat(server): …`. Add a task ID `(#NNN)` if one is assigned.
  Add the attribution trailer the session specifies.

## Commands
Before every commit run `just ci` (secrets check, format check, lint, unit tests). Note: AGENTS.md
records that `just test-unit` / `swift test` currently fail to build on macOS (pre-existing). If
`just ci` fails only for that known reason, run the unit tests through Xcode instead and say so in
the commit body:
```bash
xcodebuild test -workspace SmartTube.xcworkspace -scheme SmartTube \
  -destination "platform=iOS Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO \
  -only-testing:SmartTubeIOSTests/<SuiteName>
```
Run `xcodebuild -list -workspace SmartTube.xcworkspace` if the scheme or suite name differs.
Server tests:
```bash
cd tools/ytdlp-server && python3 -m unittest discover -s tests -v
```
`just format` fixes formatting; `just lint` runs SwiftLint.

---

## Server locking rules (apply to every Phase 1 task)
- All reads and writes of `jobs`, the sidecars, eviction, keep, and delete take `self.lock`.
- Eviction and delete **skip any id whose job is `queued` or `running`**.
- `submit()` returns `ready` for an existing `.mp4` when there is no job entry; eviction must not
  remove that file between that reply and the client's `GET`. Eviction therefore never touches the
  file that finished in the same call, and evicts oldest-first only.
- Cap arithmetic uses `os.path.getsize` of the `.mp4`, never the sidecar's `fileSize`.
- Sidecar writes are atomic: write a uniquely named temp file in the same directory, then
  `os.replace`. Listing ignores `*.tmp` files and skips (logs, never 500s on) a corrupt sidecar.
- Every id taken from a URL, body, or sidecar is checked against `VIDEO_ID_RE`; a sidecar whose
  `videoId` does not match its filename is ignored.

---

## Phase 1 — Server (`tools/ytdlp-server/server.py`)

### Task 1.1 — Metadata, sidecar, keep default
1. `POST /v1/jobs` accepts optional `title` (string, max 300 chars), `channelTitle` (string, max
   200), `duration` (number ≥ 0; a bool is rejected), `thumbnailURL` (string, `https://` only, max
   500), and `keep` (bool, default `true`). Invalid values → `400`, as `maxHeight` does.
2. Keep the posted metadata in a **separate** dict from the job state. `GET /v1/jobs/<id>` must not
   return `title`, `keep`, etc. (`status()` returns `dict(job)` today.)
3. **Order of operations in `_run`:** write the sidecar first, then set `status="ready"`. Never
   expose `ready` without a sidecar.
4. Sidecar `<id>.json`: `{videoId, title, channelTitle, duration, thumbnailURL, keep,
   downloadedAt, fileSize}`. `downloadedAt` format is exactly `%Y-%m-%dT%H:%M:%SZ` (UTC, no
   fractional seconds), so `ISO8601DateFormatter` decodes it without options.
5. **First writer wins.** If a job is already queued or running, or the file exists with a sidecar,
   the new POST's metadata is ignored. If the file exists with **no** sidecar (legacy), the POST
   backfills the sidecar from the posted metadata.
6. Verify: add tests — finished job leaves a sidecar with `keep: true` and the posted metadata;
   `GET /v1/jobs/<id>` does not leak metadata; omitted metadata still yields a valid sidecar;
   bad metadata types → 400; legacy file gets a backfilled sidecar. Then `just ci`.
7. Commit: `feat(server): sidecar metadata and keep by default`.

### Task 1.2 — Health `apiVersion`
1. `GET /v1/health` returns `"apiVersion": 2` alongside `ok` and `ytdlpVersion`.
2. Verify: test that the field is present. `just ci`.
3. Commit: `feat(server): report apiVersion 2 in health`.

### Task 1.3 — Library listing, keyset paged
1. `GET /v1/library?limit=<n>&cursor=<c>` (auth required). The query string must be parsed
   separately (`do_GET` currently strips it with `.split("?")[0]`).
2. `limit`: default 50, min 1, max 200; non-numeric or out of range → `400`.
3. Lists every `<id>.json` (valid, matching filename) whose `.mp4` exists. Sorted by
   `(downloadedAt, videoId)` descending.
4. Cursor is opaque: base64 of `"<downloadedAt>|<videoId>"` of the last item returned. The next
   page is everything strictly after that key in the sort order. A malformed cursor → `400`.
5. Response: `{"items": [ ...sidecar objects... ], "nextCursor": "<c>" | null}`.
6. Verify: tests — two pages with no overlap; a download added between page 1 and 2 causes no
   duplicate or skipped row; last page has `nextCursor: null`; empty library; sidecar without an
   `.mp4` left out; corrupt sidecar skipped; bad `limit` and bad cursor → 400; no auth → 401.
   `just ci`.
7. Commit: `feat(server): keyset-paged library listing`.

### Task 1.4 — Keep toggle
1. Add `do_PUT` (it does not exist). Copy the auth and JSON-body handling from `do_POST`,
   including the `400 bad json` path. `PUT /v1/files/<id>/keep` with body `{"keep": true|false}`;
   `keep` must be a bool, otherwise `400`. Unknown id → `404`. Response: `{"ok": true,
   "keep": <bool>}`.
2. The sidecar read-modify-write holds `self.lock`.
3. Verify: tests — set true, set false, unknown id → 404, bad body → 400, non-bool keep → 400, no
   auth → 401. `just ci`.
4. Commit: `feat(server): keep toggle endpoint`.

### Task 1.5 — Delete
1. `DELETE /v1/files/<id>` removes the `.mp4` **and** the `.json`, even if the `.mp4` is already
   missing (no orphan sidecar).
2. If the job is `queued` or `running`, return `409` and delete nothing (this prevents `_set` from
   recreating the job and the file reappearing).
3. Return `{"deleted": true}` with `200` only when something was removed; `404` with
   `{"deleted": false}` when nothing existed.
4. Verify: tests — both files removed; orphan sidecar removed; running job → 409; unknown id →
   404 with `deleted: false`. `just ci`.
5. Commit: `fix(server): delete removes the sidecar and refuses running jobs`.

### Task 1.6 — Storage policy and legacy files
1. Add `YTDLP_UNKEPT_CAP_GB` (default 20). Add an `evict()` method that can be called directly
   in tests. Follow the locking rules above. Evict unkept files oldest-first until the unkept
   total (by `getsize`) is at or under the cap. Remove `.mp4` and `.json` together and drop the
   job entry. Never evict kept files.
2. Call `evict()` after each job reaches `ready` (skipping the file just finished) and once at
   startup. Remove the old age-based `sweep` and `YTDLP_RETENTION_HOURS`; update
   `test_sweep_removes_only_old_files` and the `setUpClass` environment in
   `tests/test_server.py`, and the `manager.sweep()` call in `build_server`.
3. **Legacy files at startup:** for each `.mp4` with no sidecar, write a sidecar with
   `keep: false`, `downloadedAt` from the file's mtime, empty title/channel, so they are counted
   and evictable (they were governed by the old 24 h rule, so treating them as unkept keeps that
   spirit). Delete orphan `.json` files (no `.mp4`) and stale `*.part` / `*.tmp` / `*.f*.mp4`
   leftovers older than one hour at startup.
4. Verify: tests with explicit `downloadedAt` — three unkept files over the cap evict oldest
   first; a kept file is never evicted; under-cap evicts nothing; a running job's file is
   skipped; legacy `.mp4` is migrated as unkept; orphans removed; a kept file survives the
   startup `evict()`. `just ci`.
5. Commit: `feat(server): 20 GB cap on unkept downloads`.

### Task 1.7 — Server docs
1. Update `tools/ytdlp-server/README.md` (API table and curl examples for library, keep, delete;
   the settings list: remove `YTDLP_RETENTION_HOURS`, add `YTDLP_UNKEPT_CAP_GB`) and
   `docs/features/ytdlp-companion-server.md` (API table and the retention rule).
2. Verify: `just ci` (includes the doc-links check).
3. Commit: `docs(server): document the library, keep flag and storage cap`.

---

## Phase 2 — App client

All client types below live in `SmartTubeIOS/Sources/SmartTubeIOS/Services/YtDlpServerFetcher.swift`
alongside `YtDlpJobState` (not in Core).

### Task 2.1 — Library client calls
1. `YtDlpHealth`: add `apiVersion: Int?` (optional, so old servers still decode).
2. Add `YtDlpLibraryItem` (`videoId`, `title`, `channelTitle`, `duration`, `thumbnailURL`, `keep`,
   `downloadedAt`, `fileSize`) and `YtDlpLibraryPage` (`items`, `nextCursor`). Both `Sendable`.
   Decode `downloadedAt` with `ISO8601DateFormatter` default options (matches the server format).
3. Extend `YtDlpServerClient`: `library(cursor:limit:)`, `setKeep(videoId:keep:)`,
   `deleteFromServer(videoId:)`.
4. In `URLSessionYtDlpServerClient`:
   - Build URLs with `URLComponents` so `?cursor=&limit=` is not percent-encoded (today
     `request` uses `appendingPathComponent`).
   - Add a body-less send path for `setKeep` / `deleteFromServer` (`send<T: Decodable>` always
     decodes a body).
   - Replace the message-only `YtDlpServerError` with one that also carries the HTTP status code,
     so callers can tell 401 from 404 from a timeout. Do not map every 404 to "does not know this
     video" for library calls.
   - Make the request timeout injectable (default stays 30 s) so a 5 s probe is possible.
5. Update `FakeClient` in `YtDlpServerFetcherTests.swift` and every conformer/stub that breaks.
6. Tests: decode a library page; decode a `null` cursor; decode a health reply without
   `apiVersion`; URL, method and query string for each new call; a 401 and a 404 are
   distinguishable. For request-body checks use a `URLProtocol` stub, not the fake client.
7. `just ci`. Commit: `feat(downloads): library client for the yt-dlp server`.

### Task 2.2 — Send metadata, and `keep: false` for streaming
1. `YtDlpServerFetcher.resolve` sends `title`, `channelTitle`, `duration`, `thumbnailURL` from the
   `Video` on `createJob`. It does not send `keep`.
2. `YtDlpServerStream.resolve` (used for "Play from yt-dlp Server") sends `keep: false`.
3. Tests via a `URLProtocol` stub: body contains the metadata for downloads; `keep: false` for
   streaming; `keep` absent for downloads.
4. `just ci`. Commit: `feat(downloads): send metadata and keep:false for streaming`.

### Task 2.3 — Check the NAS before extracting
Background: `ConfigurableDownloadFetcher.resolve` in the same file.
- **Off:** never contact the server. Unchanged.
- **Always:** unchanged. `createJob` already returns `ready` for a file on disk.
- **Fallback:** if `cfg.isConfigured` and the request is **not** audio-only, probe with
  `GET /v1/jobs/{id}` (`jobState`, **not** `createJob`, which would start a yt-dlp run). On
  `ready`, call `makeServer(cfg).resolve` (this calls `createJob`, which returns `ready` straight
  away for an existing file). On `404`, any other error, or a 5-second timeout, run the native
  extractor as today.
- Audio-only downloads skip the probe (the server returns a full MP4 and ignores `audioOnly`).
- A 401 is logged and treated as "not available".
- Rethrow `CancellationError`.
1. Implement as above, using the injectable timeout and the status-carrying error from Task 2.1.
2. Tests (Swift Testing, fake client; inject the timeout, no sleeping):
   - Fallback, probe `ready`: native not called, server fetcher used.
   - Fallback, probe 404: native called.
   - Fallback, probe throws a timeout: native called.
   - Fallback, probe 401: native called and logged.
   - Fallback, not configured: probe never called.
   - Fallback, audio-only: probe never called.
   - Off: the client is never called.
   - Always: no probe call.
3. `just ci`. Commit: `feat(downloads): check the yt-dlp server before extracting in fallback mode`.

### Task 2.4 — Download from the NAS list
Background: `VideoDownloadService.enqueue` (`Services/VideoDownloadService.swift`) uses
`ConfigurableDownloadFetcher`, which follows the mode. With the mode Off, a tap on a NAS row would
not reach the NAS.
1. Add a `forceServer` option to `enqueue` that makes the fetcher use the server regardless of
   mode. It still requires `cfg.isConfigured` and respects the existing `downloadsEnabled` guard.
2. Build the `Video` for a library item from `YtDlpLibraryItem` (`id`, `title`, `channelTitle`,
   `duration`, `thumbnailURL`).
3. Tests: with mode Off and `forceServer`, the server fetcher is used; with the server
   unconfigured it fails with the existing "not set up" message.
4. `just ci`. Commit: `feat(downloads): download a NAS item to the device on demand`.

---

## Phase 3 — "Available on NAS" section (iOS only)

The section is wrapped in `#if os(iOS)`. tvOS shows nothing new (`tvOSBody` is just `emptyState`).
`NASLibraryViewModel` itself must compile for both platforms.

### Task 3.1 — Paged view model and gate
1. `NASLibraryViewModel`: `@MainActor @Observable`, takes a `YtDlpServerClient` and the local
   `DownloadStore` at the seam.
2. **Gate:** evaluated once when the screen appears and cached while it is open. The section is
   hidden if the server is not configured, `health()` fails, or `apiVersion` is missing or < 2.
   Once at least one page has loaded successfully, a later failure never hides the section (see
   Task 3.4).
3. Loads page 1 on appear and on pull-to-refresh. Loads more pages while there are fewer than
   ~20 visible rows and `nextCursor` is not null, so a page made entirely of local items cannot
   stall paging. Also loads the next page when the last visible row appears.
4. `available` = loaded items whose `videoId` is **not** in the local manifest in any state that
   is `complete`, `queued`, `downloading`, or `merging`. (Items being downloaded locally leave the
   list, so a second tap cannot silently do nothing.)
5. Tests: first page loads; second page appends; a page of all-local items triggers the next
   load; a local download (any active or complete status) is removed from `available`; gate hides
   for apiVersion 1, missing apiVersion, unreachable, unconfigured; an error after a successful
   load keeps rows and sets an error message.
6. `just ci`. Commit: `feat(downloads): paged NAS library view model`.

### Task 3.2 — Keep and delete actions in the view model
1. `setKeep(videoId:keep:)` calls the client and updates the loaded item only on success.
2. `deleteFromNAS(videoId:)` calls the client; on success remove the item from the loaded list. A
   `409` (job still running) leaves the row and sets a "still downloading on the NAS" message.
3. Tests: keep toggles and rolls back on failure; delete removes the row on success; delete
   failure and 409 keep the row and set the message.
4. `just ci`. Commit: `feat(downloads): keep and delete actions for NAS items`.

### Task 3.3 — Section UI
1. In `Views/Common/DownloadsView.swift`, add an "Available on NAS" section below the local
   downloads, inside `#if os(iOS)`. Each row: title, channel, duration, file size, and a pin icon
   (`AppSymbol.pin`, added in `Views/ViewHelpers.swift`) when `keep` is true.
2. `.swipeActions` (leading edge, `allowsFullSwipe` left at the default `true`): "Delete from
   NAS", destructive role, calling `deleteFromNAS` directly (no confirmation dialog).
   `.swipeActions` (trailing edge): "Keep" or "Unkeep", calling `setKeep`. Note: this is the
   opposite edge from the local rows' `.onDelete`; that is intended.
3. Tap a row: `enqueue(..., forceServer: true)` from Task 2.4.
4. Accessibility identifiers as listed under Rules. No UI-test files.
5. Verify: `just build` succeeds; behaviour is proven by the view-model tests in Tasks 3.1–3.2
   (the view only forwards calls). `just ci`.
6. Commit: `feat(downloads): available on NAS section`.

### Task 3.4 — Offline and refresh
1. If the server cannot be reached after at least one page has loaded, keep the loaded rows and
   show a single "NAS unreachable" line. Before any successful load, the section stays hidden
   (Task 3.1 gate).
2. Pull-to-refresh reloads page 1 and re-evaluates the gate only if the section was hidden.
3. Tests: unreachable after a successful load keeps rows and sets the message; unreachable before
   any load keeps the section hidden; refresh reloads page 1.
4. `just ci`. Commit: `feat(downloads): NAS section handles offline and refresh`.

---

## Done when
- A video the NAS already has is not re-extracted in Fallback mode (Task 2.3 tests pass).
- A kept NAS copy never expires, including across a server restart; unkept copies stay under
  20 GB (Task 1.6 tests pass).
- "Available on NAS" lists NAS items the device does not have, paged, with keep and delete on the
  row, on iOS.
- `python3 -m unittest discover -s tests -v` and `just ci` pass.

## Out of scope
- Uploading device downloads to the NAS.
- A per-device library record on the NAS (the device's own manifest is the record of what it
  holds).
- tvOS UI for the NAS section.
- Changes to `master`.

## Review changes (what the independent review caused)
Added: locking rules; sidecar-before-ready ordering; separate metadata dict; first-writer-wins and
legacy backfill; legacy-file migration and orphan cleanup; keyset cursor; `do_PUT`; delete returns
409 for running jobs and removes orphan sidecars; input validation; date format; optional
`apiVersion`; `URLComponents`, body-less sends, status-carrying errors, injectable timeout;
probe skips for audio-only and unconfigured; forced-server enqueue; gate caching and the offline
rule; iOS-only section; hiding items already downloading locally; streaming `keep: false`;
explicit `just ci` and doc updates; view-model tests instead of a UI test; the identifier and
symbol conventions that match the real code.
