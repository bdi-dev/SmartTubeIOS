# Lint cleanup since the fork from master — implementation plan

> Audience: a small model (Haiku) executing step by step. Do ONE task at a time, run its
> verification, then commit. Do not skip ahead, do not redesign, do not fix anything not listed.
> Branch: `feat/tvos-mpv-extractor-split`. It forked from `master` at `38d563ed` (master's tip).
> Measured on HEAD `0dbdf0f`, 2026-11-23, SwiftLint 0.65.1, `xcrun swift-format` from Xcode.

## Goal
Clear every SwiftLint and swift-format violation that this branch **introduced** since it forked
from `master`, so that new work is clean and the lint baseline can be made honest again. Violations
that already exist identically on `master` are out of scope (see "Out of scope").

## Evidence (how the numbers were obtained)
A detached worktree of `master` and the main checkout were both linted with no baseline:
- SwiftLint: `swiftlint lint --quiet --config .swiftlint.yml 2>&1 | grep -E "error:|warning:"`
  (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` exported; output is on stderr).
- swift-format: the `format-check` command from the `justfile`.
- Output was de-duplicated (swift-format and SwiftLint both print some violations twice), paths
  normalised, and counted per (file, rule).
- A violation counts as **introduced** when its line is an added line in `git diff -U0
  master...HEAD`. Cross-check: the per-(file, rule) count delta against master gives 151 net;
  the added-line method gives 153; plus one `function_body_length` that the branch caused by
  growing an unchanged-line initializer (`AppSettings.swift`, 81 lines vs the 80 limit). The task
  tables below use 154.
- 69 Swift files changed on the branch (31 are new). All introduced violations are in changed
  files; there are 0 in files the branch did not touch.

Totals without baseline: SwiftLint master 1418, HEAD 1558 (unique). swift-format master 1505
unique violations in 35 files, HEAD 1374 in 28 files (the branch net-reduced it).

### SwiftLint: introduced by the branch = 154
| Rule | Count | Where |
|---|---|---|
| `identifier_name` (1-letter names) | 60 | tests 46, sources 14 |
| `raw_accessibility_identifier` | 39 | views |
| `async_without_await` | 24 | tests 21, sources 3 |
| `force_unwrapping` | 18 | tests 12, sources 6 |
| `large_tuple` | 3 | `InnerTubeDownloadFetcher` 2, `NewUploadNotifierTests` 1 |
| `modifier_order` | 2 | `DownloadStore`, `DownloadStorage` |
| `static_over_final_class` | 2 | `YtDlpServerClientURLTests` |
| `function_body_length` | 2 | `InnerTubeDownloadFetcher` (81 lines), `AppSettings` init (81 lines) |
| `implicit_optional_initialization` | 1 | `Video.swift` |
| `file_length` | 1 | `SettingsView.swift` (717 lines, limit 600; master was under) |
| `for_where` | 1 | `BackgroundDownloadSession` |
| `verbatim_text_without_reason` | 1 | `TVSidebarRootView.swift:280` |

### swift-format: introduced by the branch = 9, all in `SmartTubeApp/Sources/AppEntry.swift`
7 `Indentation` (lines 309-315, the new `Task { ... }` block inside an already mis-indented
region) and 2 `LineLength`. `AppEntry.swift` has 61 swift-format violations in total (89 on master);
formatting the file fixes all of them. No other branch-changed file gained any. The branch also
removed 130 swift-format violations in files it changed.

### Not introduced (no action): the MPV files
`MPVPlayerView.swift` (16) and `MPVPlayerViewModel.swift` (2) have swift-format violations, but
the same numbers exist on master. They introduced no SwiftLint violations. Do not touch them.

## The baseline, and why `just lint` does not work (facts)
`just lint` runs `swiftlint lint --strict --baseline .swiftlint.baseline --config .swiftlint.yml`.
- `.swiftlint.baseline` is one line of JSON with 1162 entries, keyed on relative file path, rule,
  line text and reason. It is byte-identical on `master` and HEAD.
- It was last written in `a50cf22` (the InnerTubeKit move), which is 66 commits behind `master`.
  Code has changed since, so some entries are stale and newer files have no entries.
- **`just lint` already fails on `master` itself.** Linting a clean master worktree with the
  baseline still reports **444** strict violations (1419 without the baseline, so the baseline
  suppresses about 975 of its 1162 entries). Of the 444, 327 are in a (file, rule) pair the
  baseline has no entry for at all (code added after `a50cf22`); the rest are stale line text.
- On HEAD the same command reports 605 unique violations (620 with duplicates). 605 - 444 = 161,
  which is the 154 introduced plus a few lines that differ from master's text.
- **Path-dependent suppression.** A master worktree under `/private/tmp/...` (the scratchpad)
  reported 1419 with the baseline, i.e. nothing suppressed. The identical worktree under
  `/Users/ianboyd/DevTemp/` reported 444, i.e. suppression worked. Cause not proven (the relative
  paths in the baseline are not absolute; the symlink `/tmp -> private/tmp` is the suspect).
  Rule: **always run SwiftLint with a baseline from a checkout under `/Users/ianboyd/`**, never
  from `/tmp` or the scratchpad.
- Config warning on every run: `'unused_private_declaration' is not a valid rule identifier`
  (it is an analyzer rule in 0.65.1 but is listed under `opt_in_rules`). It is printed as a
  `warning:` line. Exclude it when counting (commands below do). Fixing it is out of scope.

**Decision in this plan:** do NOT regenerate the baseline from HEAD (that would freeze the 154
violations this plan removes). Fix the 154 first (Tasks 1-10), then in Task 11 regenerate the
baseline from a **master** worktree created under `/Users/ianboyd/DevTemp/`, so the baseline
contains only violations that exist on master. Whatever then still fails on HEAD is, by
construction, something the branch introduced.

## Rules (from AGENTS.md — follow exactly)
- Swift 6 strict concurrency. `@MainActor @Observable` view models. No Combine / `@Published` /
  `DispatchQueue` / completion handlers in new code.
- `SmartTubeIOSCore` is Foundation-only. Never add SwiftUI/UIKit there.
- **Real fixes over suppressions.** A `// swiftlint:disable:next <rule>` is allowed only where a
  task says so, and it must carry a reason on a separate comment line directly above the plain
  disable line: `// Reason: protocol witness must stay async` then
  `// swiftlint:disable:next async_without_await`. SwiftLint 0.65.1 rejects a `--` reason on the
  disable line itself. Never use a file-wide or block `disable`. Never edit
  `.swiftlint.yml` or `.swift-format` in this plan.
- **Behaviour must not change.** These are lint fixes. Do not change logic, signatures that other
  files call (unless the task says so), strings, or accessibility identifier values.
- Never edit `project.pbxproj`. Do not add UI-test files. UI tests refer to accessibility ids by
  string literal, so every id string must stay byte-identical.
- Unit tests use Swift Testing; no `Task.sleep`, no live network. Do not "fix" a test by deleting
  assertions.
- Links inside this plan use backticks, not relative markdown links, because the repo's
  `doc-links` check resolves links relative to this folder.
- Commits: Conventional Commits, e.g. `style(lint): …`. End each commit message with the
  attribution trailer the session specifies. Do not push.
- Do not switch branches. Do not run `git add -A`; add only the files the task lists.
- **One foreground build/test at a time.** Never start a second `xcodebuild` while one runs.
- **Disk guard.** Before every task and before every `xcodebuild`, run
  `df -h /System/Volumes/Data | tail -1`. If free space (`Avail`) is under 4 GB, STOP and report;
  do not delete anything yourself. (Free space was 8.4 GB when this plan was written.)

## Known failures that are NOT ours — do not fix
`HomeViewModelTests`, `BrowseViewModelTests`, `SearchViewModelFeedHideTests`,
`ChannelViewModelFeedHideTests` and `TOSPlaybackEndAutoplayTests` fail on `master` too. If one of
these fails, note it and carry on; it is not caused by a lint fix. Any OTHER failing suite means
your change broke something: revert the task's edits (`git checkout -- <files>`) and report.

## Commands
A Claude Code hook (`scripts/hooks/swift-post-edit.sh`) runs after each `.swift` edit, formats the
file and reports violations the edit added; if it reports one, fix it before moving on.
Set once per shell:
```bash
cd /Users/ianboyd/Dev/SmartTubeIOS
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```
`just` is not installed here; use these instead of `just`.

SwiftLint on given files, ONE FILE PER CALL (passing several paths to one call lints the whole
tree, not just those files; SwiftLint writes to stderr):
```bash
for f in <file1> <file2>; do swiftlint lint --quiet --config .swiftlint.yml "$f" 2>&1 \
  | grep -E "error:|warning:" | grep -v "not a valid rule" | sort -u; done
# count only (per file):   swiftlint lint --quiet --config .swiftlint.yml "$f" 2>&1 | grep -E "error:|warning:" | grep -v "not a valid rule" | wc -l
# one rule only:           ... | grep -c "(identifier_name)"
```
swift-format on given files (no output and exit code 0 means clean):
```bash
xcrun swift-format lint --strict --configuration .swift-format <file> [<file> ...]
```
Unit tests (the only test command that works on this machine; `swift test` hits a known macOS
compile break, the `SmartTube` scheme has no unit test plan):
```bash
cd SmartTubeIOS && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -scheme SmartTubeIOS-Package -destination "platform=iOS Simulator,name=iPhone 17" \
  CODE_SIGNING_ALLOWED=NO -only-testing:SmartTubeIOSTests/<StructName>
```
Pass `-only-testing` once per struct (repeat the flag for several). Suite struct names are given in
each task. Do not pass the `@Suite` display string.

**Per-task verify template** (every task's Verify uses this, with its own file list and counts):
1. `df` guard (above).
2. swift-format on the touched files: must print nothing. If it prints something in a line you did
   not touch and that exists on master, leave it and note it. Lines you added or edited must be
   clean. If a touched file already had swift-format violations before your edit (only
   `AppEntry.swift` does), run `xcrun swift-format format --in-place --configuration .swift-format
   <file>` only where the task says so.
3. SwiftLint on the touched files: the count of the rules the task names must drop by exactly the
   stated number (compare to the "before" count captured in step 1 of the task). No new rule may
   appear.
4. The task's unit tests: all pass, except the known failures above.

Keep the "before" capture in a scratch file, not in the repo.

---

## Task 0 — Pre-flight (no commit)
1. `git status --short` must be empty and `git branch --show-current` must print
   `feat/tvos-mpv-extractor-split`. If not, stop and report.
2. Disk guard.
3. Confirm the starting counts for the whole tree (takes about 1 minute):
   `swiftlint lint --quiet --config .swiftlint.yml 2>&1 | grep -E "error:|warning:" | grep -v
   "not a valid rule" | sort -u | wc -l` should print about **1558** (±2 is fine; report if it
   differs by more).
4. Do not run `just`, do not regenerate the baseline, do not format the whole tree.

---

## Phase A — tests (lowest risk, 82 violations)

### Task 1 — `VideoDownloadServiceTests.swift` (39)
File: `SmartTubeIOS/Tests/SmartTubeIOSTests/VideoDownloadServiceTests.swift`
Rules: `identifier_name` 28 (mostly `h`, also `i`, `c`, `s`), `async_without_await` 6,
`force_unwrapping` 5.
1. Capture the before-counts for this file (template step 3).
2. `identifier_name`: rename the one-letter variable/closure parameter to a meaningful name
   (`h` -> `handle` or `holder` — read the code to choose; `i` -> `index`; `c` -> `config` /
   `count` by use). Rename every use in scope. Do not add the name to `.swiftlint.yml`.
3. `async_without_await`: for each `@Test func ... async` that never uses `await`, remove `async`
   (and `throws` stays if present). If removing `async` produces a compiler error because the
   function is a protocol witness or is passed where an async closure is required, instead keep it
   and put `// Reason: protocol witness must stay async` followed by
   `// swiftlint:disable:next async_without_await` on the line(s) above.
4. `force_unwrapping`: in a `@Test`, replace `x!` with `try #require(x)` and mark the test
   `throws` (add `throws` if absent, keep `async` if it has `await`). In a helper that cannot
   throw, use `guard let x else { Issue.record("<what was nil>"); return <fallback> }`.
5. Verify: template with this file; expect `identifier_name` -28, `async_without_await` -6,
   `force_unwrapping` -5 (file total 0). Tests, one struct per `-only-testing` flag:
   `VideoDownloadServiceTests`, `VideoDownloadServiceBackgroundTests`,
   `VideoDownloadServiceRecoveryTests`, `VideoDownloadServiceAudioOnlyTests`,
   `VideoDownloadServicePauseTests`.
6. Commit: `git add SmartTubeIOS/Tests/SmartTubeIOSTests/VideoDownloadServiceTests.swift` then
   `style(lint): clear identifier, async and force-unwrap violations in VideoDownloadServiceTests`.

### Task 2 — yt-dlp server client tests (19)
Files: `SmartTubeIOS/Tests/SmartTubeIOSTests/YtDlpServerFetcherTests.swift` (15: `async_without_await`
9, `force_unwrapping` 3, `identifier_name` 3) and
`SmartTubeIOS/Tests/SmartTubeIOSTests/YtDlpServerClientURLTests.swift` (4: `force_unwrapping` 2,
`static_over_final_class` 2).
1. Capture before-counts.
2. Same fix styles as Task 1 for `async_without_await`, `force_unwrapping`, `identifier_name`.
3. `static_over_final_class` (`StubProtocol`, lines 14-15, `override class func canInit` and
   `canonicalRequest`): change `override class func` to `override static func` on exactly the two
   flagged declarations. If the compiler rejects it, revert that edit and use
   `// Reason: URLProtocol requires class overrides` followed by
   `// swiftlint:disable:next static_over_final_class`.
4. Verify: template; expect FetcherTests -15, ClientURLTests -4. Tests: `YtDlpServerFetcherTests`,
   `ConfigurableDownloadFetcherTests`, `YtDlpConfigTests`, `YtDlpServerStreamTests`,
   `YtDlpLibraryDecodingTests`, `YtDlpServerClientTokenTests`, `YtDlpJobMetadataTests`,
   `URLSessionYtDlpServerClientTests`.
5. Commit: `style(lint): clear violations in the yt-dlp server client tests`.

### Task 3 — upload, auto-download and store tests (24)
Files (all in `SmartTubeIOS/Tests/SmartTubeIOSTests/`): `NewUploadNotifierTests.swift` (10:
`async_without_await` 5, `identifier_name` 4, `large_tuple` 1), `WatchLaterAutoDownloadTests.swift`
(9: `identifier_name` 8, `async_without_await` 1), `NewUploadDetectorTests.swift` (4:
`identifier_name` 3, `force_unwrapping` 1), `DownloadStoreTests.swift` (1: `force_unwrapping`).
1. Capture before-counts.
2. Same fix styles as Task 1. `large_tuple` (`make(...) -> (NewUploadNotifier, FakePoster,
   SeenUploadsStore)`, `NewUploadNotifierTests.swift:46`): replace the 3-tuple return with a small
   private `struct Harness { let notifier: NewUploadNotifier; let poster: FakePoster; let seen:
   SeenUploadsStore }` declared inside the test file, and update the call sites.
3. Verify: template; expect -10, -9, -4, -1. Tests: `NewUploadNotifierTests`,
   `AutoDownloadPolicyTests`, `WatchLaterAutoDownloaderTests`, `NewUploadDetectorTests`,
   `SeenUploadsStoreTests`, `SeenUploadsStoreSourceTests`, `DownloadStoreDestinationURLTests`,
   `DownloadStoreLifecycleTests`, `DownloadJobTests`.
4. Commit: `style(lint): clear violations in the new-upload and auto-download tests`.

---

## Phase B — non-view sources (32 violations)

### Task 4 — Core and InnerTubeKit sources (17)
Files: `SmartTubeIOS/Sources/SmartTubeIOSCore/DownloadStore.swift` (9: `identifier_name` 8,
`modifier_order` 1 at line 158), `SeenUploadsStore.swift` (2 `identifier_name`),
`NewUploadDetector.swift` (2 `identifier_name`), `DownloadJob.swift` (1 `identifier_name`),
`DownloadStorage.swift` (1 `modifier_order` at line 22), `AppSettings.swift` (1
`function_body_length`, initializer at line 449, 81 lines vs 80), and
`SmartTubeIOS/Sources/InnerTubeKit/Video.swift` (1 `implicit_optional_initialization`).
1. Capture before-counts (these files also have pre-existing violations on master; only the
   introduced ones are expected to go).
2. `identifier_name`: rename one-letter names to meaningful ones; they are local, so no API change.
3. `modifier_order`: write `nonisolated public static var ...` instead of `public nonisolated
   static var ...` (nonisolated comes first). Meaning is unchanged.
4. `function_body_length` (`AppSettings` init): move one cohesive group of assignments into a
   private helper called from the init so the body is 80 lines or fewer. Do not reorder
   assignments that depend on each other. If that is not possible without risk, use
   `// Reason: settings init mirrors the stored properties` followed by
   `// swiftlint:disable:next function_body_length` and say so in the commit body.
5. `implicit_optional_initialization` (`Video.swift`): of the two flagged `var x: T? = nil`
   lines (48 and 69), only the one on an added line is ours; check with
   `git blame -L48,48 -L69,69 SmartTubeIOS/Sources/InnerTubeKit/Video.swift` (a commit not
   reachable from `master` = ours, test with `git merge-base --is-ancestor <sha> master`). Remove
   the ` = nil` from that line only. Do not touch the other (it exists on master).
6. Verify: template, expect the stated drops (`DownloadStore` -9, `SeenUploadsStore` -2,
   `NewUploadDetector` -2, `DownloadJob` -1, `DownloadStorage` -1, `AppSettings` -1, `Video` -1).
   Tests: `DownloadStoreDestinationURLTests`, `DownloadStoreLifecycleTests`, `DownloadJobTests`,
   `DownloadStorageTests`, `NewUploadDetectorTests`, `SeenUploadsStoreTests`,
   `SeenUploadsStoreSourceTests`, `NewUploadNotifierTests`, plus the settings tests if they exist:
   `grep -l AppSettings SmartTubeIOS/Tests/SmartTubeIOSTests/*.swift` and run the struct names in
   those files.
7. Commit: `style(lint): clear violations in Core download and upload sources`.

### Task 5 — Services sources and the app delegate (15)
Files: `SmartTubeIOS/Sources/SmartTubeIOS/Services/YtDlpServerFetcher.swift` (6:
`async_without_await` 2 at lines 402 and 405, `force_unwrapping` 4 at lines 436-437),
`InnerTubeDownloadFetcher.swift` (5: `force_unwrapping` 2 at lines 333-334, `function_body_length`
1 at line 311, `large_tuple` 2 at lines 115 and 162), `BackgroundDownloadSession.swift` (1
`for_where` at line 110), `VideoDownloadService.swift` (1 `identifier_name`),
`SmartTubeIOS/Sources/SmartTubeIOS/Views/Home/TVSidebarRootView.swift` (1
`verbatim_text_without_reason` at line 280), and `SmartTubeApp/Sources/AppDelegate.swift` (1
`async_without_await` at line 42).
1. Capture before-counts.
2. `async_without_await`, `YtDlpServerFetcher.swift` 402 and 405 (`UnsupportedAssembler`'s
   `resolve` and `assemble`) and `AppDelegate.swift:42` (`userNotificationCenter(_:willPresent:)`):
   these are protocol witnesses that must stay `async`. Do NOT remove `async`. Add
   `// Reason: protocol witness must stay async` followed by
   `// swiftlint:disable:next async_without_await` above each.
3. `force_unwrapping` in `YtDlpServerFetcher.swift` 436-437 (`cfg.baseURL!`, `cfg.token!` inside the
   `makeServer` default closure): unwrap once before building the fetcher:
   `guard let baseURL = cfg.baseURL, let token = cfg.token else { return nil }` ONLY if the closure
   type allows `nil` (check its declaration). If it does not, bind with `if let` and fall back to
   the same behaviour the surrounding code uses when the server is not configured. Do not invent
   new behaviour; if neither is possible, stop and ask.
4. `force_unwrapping` in `InnerTubeDownloadFetcher.swift` 333-334: bind with `guard let` to the
   existing failure path of that function (read it; it already returns/throws for a bad stream).
5. `large_tuple` (lines 115 and 162, `(String, String, () async throws -> PlayerInfo)`): introduce a
   `private struct ClientCandidate { let name: String; let label: String; let load: () async
   throws -> PlayerInfo }` (name the two strings after how they are used) and use it for both.
6. `function_body_length` (`muxedStream`, line 311, 81 lines): with the struct above the body
   shrinks; if still over 80, extract the candidate-list construction into a private static
   helper.
7. `for_where` (`BackgroundDownloadSession.swift:110`): move the single `if` condition into the
   `for ... where <condition>` clause.
8. `identifier_name` (`VideoDownloadService.swift`): rename the one-letter local.
9. `verbatim_text_without_reason` (`TVSidebarRootView.swift:280`, `Text(verbatim: title)`): the
   sidebar title is already a localised/display string passed in, so the verbatim is intentional.
   Append `// verbatim: sidebar title is already localised by the caller` on that same line
   (the rule requires this exact `// verbatim:` form). Check how `title` is produced first; if it
   is a raw localisation key, use `Text(title)` instead and tell the user in the commit body.
10. Verify: template; expect each file's stated drop. Tests: `YtDlpServerFetcherTests`,
    `ConfigurableDownloadFetcherTests`, `YtDlpServerStreamTests`, `VideoDownloadServiceTests`,
    `VideoDownloadServiceBackgroundTests`, `VideoDownloadServiceRecoveryTests`; plus any struct in
    `grep -l "InnerTubeDownloadFetcher\|BackgroundDownloadSession" SmartTubeIOS/Tests/SmartTubeIOSTests/*.swift`.
11. Commit: `style(lint): clear violations in download services and the app delegate`.

---

## Phase C — accessibility identifiers (39) and file length (1)

Background: **no `AccessibilityID` type exists in the code.** The current AGENTS.md says it is
planned, and tells you to use dotted string identifiers until it exists, while the custom rule
still warns on the raw literal. This phase therefore needs the user's decision (Open decision 1);
do not start Tasks 6-8 or 10 until it is answered. If the answer is "create it": The rule
`raw_accessibility_identifier` flags the literal form `accessibilityIdentifier("`. Fix = introduce a
small `AccessibilityID` type and call `.accessibilityIdentifier(AccessibilityID.x)`. Every resulting
string value must be byte-identical to today's literal, because UI tests match on strings. 159
legacy literals stay (they are in the master baseline); convert only the 39 on added lines.
Find which lines are ours with `git blame` as in Task 4, or: a flagged line whose text does not
appear in `git show master:<file>` is ours.

### Task 6 — Introduce `AccessibilityID` and convert `DownloadsView` (13)
Files: new `SmartTubeIOS/Sources/SmartTubeIOS/Views/Common/AccessibilityID.swift`;
`SmartTubeIOS/Sources/SmartTubeIOS/Views/Common/DownloadsView.swift` (13 `raw_accessibility_identifier`).
1. Capture before-count for `DownloadsView.swift`.
2. Create `enum AccessibilityID` (internal, in the `SmartTubeIOS` target, SwiftUI-free, a plain
   enum with `static let` strings and `static func` for ids with a video id). Namespace it:
   `enum Downloads { static let enableToggle = "downloads.enableToggle"; static func videoRow(_ id:
   String) -> String { "downloads.videoRow.\(id)" } ... }` and so on for every id used by the 13
   flagged lines. Copy each string exactly from the existing literal, including interpolations.
   Do not add ids that are not used.
3. Replace each of the 13 flagged `accessibilityIdentifier("...")` with
   `accessibilityIdentifier(AccessibilityID.Downloads.<name>)`. Leave the legacy literals alone.
4. Verify: template; `DownloadsView.swift` drops by 13; `AccessibilityID.swift` has 0 SwiftLint
   and 0 swift-format output. Add a unit test file is NOT required; instead run
   `grep -rn 'downloads\.' SmartTubeApp/UITests | head` and confirm every UI-test id string still
   has an exact match in `AccessibilityID.swift` or in `DownloadsView.swift`. Build proof: the
   test command below compiles the target. Tests: `DownloadStoreLifecycleTests`.
5. Commit: `refactor(a11y): add AccessibilityID and use it in DownloadsView`.

### Task 7 — `SettingsView` identifiers and file length (11)
File: `SmartTubeIOS/Sources/SmartTubeIOS/Views/Settings/SettingsView.swift` (10
`raw_accessibility_identifier`, 1 `file_length`: 717 non-comment lines, limit 600; master was under).
1. Capture before-counts.
2. Convert the 10 ids with a `Settings` namespace in `AccessibilityID.swift` (same rules as Task 6).
3. `file_length`: move one self-contained section (the downloads / yt-dlp server settings
   `Section`s the branch added) into `SettingsView+Downloads.swift` in the same folder as an
   `extension SettingsView` with a `@ViewBuilder var downloadsSection: some View`. Properties it
   uses must be at least `internal` (not `private`); change `private` to nothing only for those
   members. Pure move, no logic edits. Goal: both files 600 lines or fewer.
4. Verify: template on each of `SettingsView.swift`, `SettingsView+Downloads.swift`, `AccessibilityID.swift`
   (one SwiftLint call per file; expect -11 total, no new violations in the new file). Tests: settings-related structs:
   `grep -l "SettingsView\|AppSettings" SmartTubeIOS/Tests/SmartTubeIOSTests/*.swift`; if none
   reference views, run `YtDlpConfigTests` and `DownloadStoreLifecycleTests` as a compile check.
5. Commit: `refactor(settings): AccessibilityID for new ids; split downloads settings out of SettingsView`.

### Task 8 — Browse and shared view identifiers (8)
Files: `Views/Browse/VideoCardView.swift` (6), `Views/RootView.swift` (1),
`Views/Common/ToastModifier.swift` (1) (all under `SmartTubeIOS/Sources/SmartTubeIOS/`).
1. Capture before-counts.
2. Convert with new namespaces (`VideoCard`, `Root`, `Toast`) in `AccessibilityID.swift`.
3. Verify: template; expect -6, -1, -1. Do not touch the pre-existing `file_length` on
   `VideoCardView.swift` (it exists on master). Tests: compile check via
   `DownloadStoreLifecycleTests` plus `grep -l "VideoCard\|Toast" SmartTubeIOS/Tests/SmartTubeIOSTests/*.swift`
   struct names.
4. Commit: `refactor(a11y): AccessibilityID for VideoCard, root and toast ids`.

---

## Phase D — formatting (9, one file)

### Task 9 — `AppEntry.swift` swift-format
File: `SmartTubeApp/Sources/AppEntry.swift` (9 introduced, 61 total on HEAD, 89 on master).
1. Capture before: `xcrun swift-format lint --strict --configuration .swift-format
   SmartTubeApp/Sources/AppEntry.swift 2>&1 | sort -u | wc -l` (about 61).
2. Run `xcrun swift-format format --in-place --configuration .swift-format
   SmartTubeApp/Sources/AppEntry.swift`.
3. Review `git diff SmartTubeApp/Sources/AppEntry.swift`: it must be whitespace and line-wrapping
   only. Confirm with `git diff -w --stat` that non-whitespace changes are only line wraps. If
   the formatter moved or removed any `#if` / `#endif`, revert and stop.
4. Verify: swift-format on the file prints nothing. SwiftLint on the file: count unchanged versus
   before (the two baselined violations `type_body_length` and `force_unwrapping` stay). This file
   is not compiled by the package, so compile it: from the repo root run
   `xcodebuild build -workspace SmartTube.xcworkspace -scheme SmartTube -destination "platform=iOS
   Simulator,name=iPhone 17" CODE_SIGNING_ALLOWED=NO -quiet` (disk guard first; one build at a
   time; `SMARTTUBE_DERIVED_DATA` default is under `~/DevTemp`). It must end without `error:`.
5. Commit: `style(app): swift-format AppEntry`.

---

## Phase E — player views (last: tvOS / mpv / playback risk)

### Task 10 — Player view identifiers (8)
Files (under `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/`): `TOSPlayerView.swift` (4
`raw_accessibility_identifier`), `PlayerView+Overlays.swift` (3), `PlayerView+ControlElements.swift` (1).
Why last: these compile into the player used on tvOS and iOS. The change is a string-constant
swap, but a wrong string silently breaks UI tests and tvOS focus tests, so be exact.
1. Capture before-counts.
2. Convert with a `Player` namespace in `AccessibilityID.swift`. Copy strings exactly.
3. Do NOT touch `TOSPlayerView`'s `function_body_length` (111 lines) or any file-length warnings
   in these files: they are identical on master and out of scope. Do not touch
   `Views/Player/MPV/*`.
4. Verify: template; expect -4, -3, -1. Tests: `grep -l "TOSPlayer\|PlayerView" SmartTubeIOS/Tests/SmartTubeIOSTests/*.swift`
   and run each struct (remember `TOSPlaybackEndAutoplayTests` fails on master; ignore only that
   one). Then compile tvOS if these files are not wholly inside `#if os(iOS)`:
   `xcodebuild build -workspace SmartTube.xcworkspace -scheme "Smart Tube" -destination "platform=tvOS Simulator,name=Apple TV" CODE_SIGNING_ALLOWED=NO -quiet`
   (the `just build-tvos` recipe; this was not run while writing the plan, so if the simulator
   name is wrong run `xcrun simctl list devices available | grep -i "apple tv"` and use that
   name). Also grep the UI tests: `grep -rn "<each id string>" SmartTubeApp/UITests` must still
   find the same strings.
5. Commit: `refactor(a11y): AccessibilityID for player ids`.

---

## Phase F — make the gate meaningful

### Task 11 — Regenerate the baseline from `master`
Goal: `.swiftlint.baseline` freezes only what exists on `master`.
1. Disk guard. Create the worktree **under `/Users/ianboyd/DevTemp/`, not `/tmp`** (see the
   path-dependent suppression above):
   `git worktree add --detach /Users/ianboyd/DevTemp/lint_master master`
2. `cd /Users/ianboyd/DevTemp/lint_master && swiftlint lint --write-baseline
   /Users/ianboyd/DevTemp/lint_master.baseline --config .swiftlint.yml || true`
   (this is the `lint-baseline` recipe pointed at a temp file; `|| true` is there because the
   command exits non-zero when it finds violations).
3. Copy: `cp /Users/ianboyd/DevTemp/lint_master.baseline /Users/ianboyd/Dev/SmartTubeIOS/.swiftlint.baseline`.
4. Remove the worktree: `cd /Users/ianboyd/Dev/SmartTubeIOS && git worktree remove --force
   /Users/ianboyd/DevTemp/lint_master && rm /Users/ianboyd/DevTemp/lint_master.baseline`.
   `git worktree list` must show only the main checkout.
5. Verify (this is the real test of Tasks 1-10): in the main checkout run
   `swiftlint lint --strict --baseline .swiftlint.baseline --config .swiftlint.yml 2>&1 | grep -E
   "error:|warning:" | grep -v "not a valid rule" | sort -u`.
   Expected: **0**. Any line printed is a violation that is on HEAD but not on master: it is
   either a leftover from Tasks 1-10 (fix it in a follow-up commit with the same styles) or a line
   the branch edited without changing the text-matched entry. Report anything you cannot clear.
   A line that is textually identical to a master line may be silently baselined; this is accepted.
   Also run Task 0 step 3 again without the baseline; the expected unique total is about
   **1418** (master's) or lower, never above it.
6. Commit: `build(lint): regenerate SwiftLint baseline from master`
   (add only `.swiftlint.baseline`; the file is a single JSON line so do not review the diff).

### Task 12 — Final gate: what `just ci` needs
`just ci` = `secrets-check doc-links format-check lint test-unit`. Run each part by hand:
1. `scripts/check-no-secrets.sh` — expected to pass; fix nothing here, report if it fails.
2. `scripts/check-doc-links.sh` — must pass. This plan file uses backticks only, so it should.
3. `format-check` (the full command in the `justfile`) — **cannot pass today for reasons outside
   this plan**: master itself has 1505 violations in 35 files and HEAD has 1374 in 28 files, of
   which 24 files were not touched by the branch. After Task 9 the branch introduced none, but
   the check is repo-wide, so it stays red until those 27 remaining files are formatted. That is
   the optional Task 13.
4. `lint` (`just lint`) — passes iff Task 11's Verify printed 0 (it runs with `--strict`; strict
   also turns the config `warning:` about `unused_private_declaration` into... nothing, it is a
   config message and not a violation; if `swiftlint` exits non-zero only because of that line,
   report it and do not edit `.swiftlint.yml`).
5. `test-unit` (`swift test --parallel`) — **cannot pass on this machine and cannot be made to
   pass by lint work**: `swift test` fails to build for native macOS because of the pre-existing
   compile break in `TOSPlayerView.swift` / `TOSPlayerViewModel+WebBridge.swift`
   (see AGENTS.md Gotchas and `docs/modernization/workstreams/WS1-entry-point-and-gates.md`;
   WS4/WS5 scope). Substitute the `xcodebuild test` command above run over the whole
   `SmartTubeIOSTests` target (`-only-testing:SmartTubeIOSTests`). Expected: everything passes
   except the five known master failures listed above.
6. Report a table: secrets-check / doc-links / format-check / lint / test-unit with pass or fail
   and the reason. Do not mark the gate green unless all five are.

### Task 13 (OPTIONAL — needs the user's decision) — format the legacy files
The 27 files that still fail `format-check` (24 not touched by the branch, plus `ChannelView.swift`,
`MPVPlayerView.swift`, `MPVPlayerViewModel.swift`). Mechanical: `just format` equivalent
(`xcrun swift-format format --in-place --recursive --configuration .swift-format <the same five
paths as the justfile>`). Risk: `MPVPlayerView.swift` and `MPVPlayerViewModel.swift` are tvOS-only
playback code; formatting touches whitespace only, but run the tvOS build and the Task 10 tests
afterwards. Do this as one commit per directory so a bad hunk can be reverted: commit message
`style: swift-format <directory>`. Do not start it unless the user says yes.

---

## Rules that cannot be fixed without behaviour risk (summary)
- `async_without_await` on protocol witnesses (`UnsupportedAssembler.resolve/assemble`, the
  `UNUserNotificationCenterDelegate.willPresent` method): removing `async` stops the type
  conforming. Use the reasoned `disable:next` (3 sites). Test functions: drop `async`.
- `force_unwrapping` in tests: use `try #require` (Swift Testing). It changes a crash into a test
  failure, which is the intent. In sources (6 sites) bind with `guard let` onto the existing
  failure path; if no failure path exists, stop and ask rather than invent one.
- `static_over_final_class` on `URLProtocol` overrides: `override static func` is valid but verify
  it compiles; otherwise reasoned `disable:next`.
- `raw_accessibility_identifier`: safe only if every string stays byte-identical. UI tests
  (`SmartTubeApp/UITests`) are not compiled by the package test command, so grep them.
- `verbatim_text_without_reason`: needs a human decision if the string turns out to be a key.

## Done when
- Tasks 1-10 are committed one by one, each with its Verify passing.
- The introduced counts reach 0: SwiftLint 154 -> 0, swift-format 9 -> 0.
- Task 11 leaves `swiftlint lint --strict --baseline` at 0 on HEAD.
- Task 12's table is reported, with `format-check` and `test-unit` honestly marked as failing for
  the reasons given unless the user approved Task 13 and the macOS compile break was fixed
  elsewhere.

## Out of scope
- Every violation that exists identically on `master` (1418 SwiftLint, 1505 swift-format),
  including `file_length` / `type_body_length` on big views, the 444 baseline-leaking master
  violations, the legacy `print_in_sources`, `inclusive_language`, `force_try` etc.
- The `unused_private_declaration` config warning, `.swiftlint.yml` and `.swift-format` edits.
- The macOS compile break in `TOSPlayerView.swift`; the five known failing test suites.
- Changing behaviour, adding features, or touching `Views/Player/MPV/`.

## Open decisions for the user
1. `AccessibilityID` does not exist; Tasks 6-8 and 10 create it. Alternative: leave the 39
   literals and re-baseline them (this conflicts with the rule warning, so the plan assumes creating the type; AGENTS.md currently only says it is planned).
2. Task 11 regenerates the baseline from master (recommended) versus leaving the stale one.
3. Task 13: format the 27 legacy files so `format-check` can pass, or leave `format-check` red.
4. `test-unit` cannot pass until the macOS compile break is fixed; decide whether the gate should
   use the `xcodebuild test` substitute instead of `swift test` (a `justfile` change, not made here).

## Known debt accepted into the baseline

The regenerated `.swiftlint.baseline` (commit `571aa45`, from the branch tip) accepts 21 structural
violations that the branch grew. They are not fixed here because each needs a refactor, not a
lint edit. `swiftlint lint --strict --baseline` stays green while they exist. Remove an entry
only when its refactor lands.

| File | Rule (current / limit) | Why it needs a refactor | One-line suggested split |
|---|---|---|---|
| `SmartTubeApp/Sources/AppEntry.swift` | `type_body_length` (544 / 400) | One app type owns scene setup, routing and wiring | Move scene and route wiring into extensions in separate files |
| `SmartTubeApp/UITests/LibraryUITests.swift` | `type_body_length` (514 / 400) | One class holds every library UI test | Split by library section into separate test classes (add in Xcode) |
| `SmartTubeIOS/Sources/SmartTubeIOS/Services/VideoDownloadService.swift` | `type_body_length` (500 / 400) | State machine, persistence and notifications in one class | Extract persistence and recovery into a helper type |
| `SmartTubeIOS/Sources/SmartTubeIOS/ViewModels/PlaybackViewModel+Loading.swift` | `file_length` (1129 / 600), `function_body_length` (618 / 150), `cyclomatic_complexity` (76 / 15) | One loading function holds the whole fallback ladder; WS4 decomposition, no new branches | Replace the ladder with one step per stream source behind a `StreamSource` |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Browse/VideoCardView.swift` | `type_body_length` (615 / 600), `file_length` (641 / 600) | Menu and overlay subviews live in the card file | Move the menu and overlay subviews into their own files |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/MPV/MPVPlayerView.swift` | `file_length` (953 / 600), `type_body_length` (897 / 600), `function_body_length` (151 / 150), `cyclomatic_complexity` (35 / 15) | tvOS-only view with transport, focus and menus in one type; needs a tvOS build to verify | Move transport focus handling and menus into extension files |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/MPV/MPVPlayerViewModel.swift` | `file_length` (949 / 600), `type_body_length` (900 / 600) | tvOS-only view model with track selection and transport in one type | Move track selection into an extension file |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/PlayerView+ControlElements.swift` | `file_length` (816 / 600) | Many control groups in one extension file | Move one control group into its own extension file |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/PlayerView+Lifecycle.swift` | `file_length` (816 / 600) | Lifecycle observers share a file with other player logic | Move observers into a separate extension file |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/PlayerView+Overlays.swift` | `file_length` (728 / 600) | More-menu overlay lives with other overlays | Move the more-menu overlay into its own file |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Player/TOSPlayerView.swift` | `file_length` (709 / 600), `type_body_length` (615 / 600), `function_body_length` (111 / 80) | Large body function and view type | Move the more-menu section into an extension and split the body function |
| `SmartTubeIOS/Sources/SmartTubeIOS/Views/Settings/SettingsView.swift` | `type_body_length` (454 / 400) | Downloads and yt-dlp sections sit in the main view | Move the downloads section into `SettingsView+Downloads.swift` (plan Task 7, step 3) |

Count: 21 (file_length 8, type_body_length 8, function_body_length 3, cyclomatic_complexity 2).
The MPV rows are tvOS-only and need a tvOS build to verify any change.
