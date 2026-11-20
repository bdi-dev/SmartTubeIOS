# 09 - iOS comments: replies and paging

## Goal
The tvOS mpv player opens a comment's replies and pages further comments. The iOS/iPadOS player's comments overlay does neither. Bring parity, using the shared API.

## Current code
- Shared, already built and tested: `InnerTubeKit/InnerTubeAPI+Social.swift` `fetchCommentPage`, `fetchCommentReplies`; `Comment.replyCountText` / `replyContinuationToken` in `InnerTubeModels.swift`; tests `CommentsPagingTests`, `CommentRepliesTests`.
- tvOS reference: `Views/Player/MPV/MPVCommentsPanel.swift` and the comments section of `MPVPlayerViewModel.swift` (state machine for load, paging, expanded thread).
- iOS: `SmartTubeIOS/Sources/SmartTubeIOS/PlayerFeatures/CommentsController.swift`, `PlayerFeatures/CommentsOverlayView.swift`, `Views/Player/PlayerView+AuxViews.swift`, `TOSPlayerViewModel+Comments.swift`.

## Plan
1. Read the tvOS implementation and the iOS controller; list what iOS lacks (replies, paging, loading and error states).
2. Extend `CommentsController` (`@MainActor @Observable`, no Combine): load the next page when the last comment appears; expand/collapse a comment's replies (one open thread at a time is fine); per-thread loading and error state; dedupe by comment id. Reuse the shared API only: do not duplicate parsing.
3. Overlay UI: a "N replies" button under a comment (use `replyCountText`), replies indented under the parent, a spinner row while paging, a retry row on error. Native iOS styling (system list/disclosure patterns, Dynamic Type, VoiceOver labels, 44 pt targets), no tvOS focus code.
4. Unit tests for the controller with a fake API: paging appends and dedupes, reply expand/collapse, failure then retry.
5. Build the iOS scheme for a simulator; if a simulator run with a signed-out session can show comments on a public video, take a screenshot of an expanded thread.

## Done when
Tests pass, iOS scheme builds, and you state exactly what you saw running vs read.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `AGENTS.md` and `.claude/rules/swift.md` first: Swift 6 strict concurrency, `@MainActor @Observable` view models, `SmartTubeIOSCore` Foundation-only, identifiers from `AccessibilityID`, symbols from `AppSymbol`, no `Task.sleep` or live network in unit tests, fakes at protocol seams.
- Never push, never open a PR, never touch `project.pbxproj`. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Use your own derived data (`~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned simulator (`xcrun simctl clone`), deleted afterwards. Unit tests: scheme `SmartTubeIOS-Package`, a simulator destination by id (the package does not build for macOS: known, unrelated). Other agents edit other files at the same time: touch only the files your plan names.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

