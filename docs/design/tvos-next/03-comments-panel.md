# Plan 3 — Comments side panel (video keeps playing)

## Goal
A **Comments** button in the controls opens a panel on the **right side** (~38% width). The video shrinks into the left/upper-left area (aspect-fit, ~62% width, vertically centred) and keeps playing with audio. Comments scroll in the panel. Back closes the panel and the video returns to full screen.

## Existing pieces
- API: `InnerTubeAPI.fetchComments(videoId:) -> [Comment]` (`InnerTubeAPI+Social.swift`). It uses the WEB client: `/next` for the continuation token, then a second `/next` for comments. Returns **first page only**, empty when disabled/absent. `Comment` model: id, author, authorAvatarURL, text, likeCount, publishedTime, isLiked (`InnerTubeModels.swift`).
- Existing UI to borrow from: `PlayerFeatures/CommentsController.swift` (state: loading/error/comments) and `PlayerFeatures/CommentsOverlayView.swift`, `Views/Player/PlayerView+AuxViews.swift` `CommentRowView`. Check which are `#if os(iOS)`; reuse the controller, write a tvOS row.
- No pagination exists. Page 2+ needs continuation-token parsing — see step 2.

## Behaviour spec
1. Comments button in the transport row (symbol `text.bubble` — add `AppSymbol.comments`), placed after the audio/chapters menus. Hidden when the video has comments disabled once known (see step 3); show while unknown.
2. Select opens the panel. Layout animates (0.3 s): video frame animates from full-screen to the left region; panel slides in from the right with a dark translucent background.
3. Panel: header "Comments (N)" when count known; list of comment rows: avatar (circle), author (bold), time, text (max ~6 lines, "…" truncation; focused row shows full text — expands in place), like count with heart/thumb icon. Rows are focusable so the list scrolls with the remote (tvOS scrolls to keep focus visible). Loading spinner, empty state ("Comments are turned off" / "No comments"), error with Retry.
4. Pagination: when focus reaches the last ~5 rows, load the next page (append). Stop when no token.
5. Controls while open: hidden. The panel owns focus. Back closes panel → focus returns to the Comments button if controls were visible, else `.surface`.
6. Playback continues; audio unchanged. Time/progress flash: keep the thin progress bar under the shrunken video so the user sees position (optional, nice to have).
7. The video surface during the shrink must not recreate the engine. Animate via `.scaleEffect`/frame on the existing `MPVVideoSurface` (`.id(ObjectIdentifier(engine))` must stay) — verify no black flash; the layer-swap bug fixed in `9e69054` came from view identity, so keep identity stable.
8. Sort: top comments (default). Sort toggle is out of scope.
9. Replies, posting, liking: out of scope (read-only).
10. Sign-in: anonymous fetch works for most videos; if not, show the empty/error state, never crash.

## Implementation steps
1. **Spike (30 min)**: in Simulator, call `fetchComments` for 3 videos (popular, comments-off, short) and log counts. Report findings in the commit message. If it returns empty for popular videos, stop and ask the owner.
2. **Pagination API**: extend `fetchComments(videoId:continuation:) -> CommentPage { comments, nextToken, totalCount }` keeping the existing signature as a wrapper so iOS code is untouched. Parse next-page `continuationItemRenderer` token and the count header (`commentsHeaderRenderer.countText`). Add unit tests with a captured fixture JSON in `SmartTubeIOS/Tests/...` (see how existing parsers are tested).
3. **VM**: `MPVPlayerViewModel` gets `commentsVisible`, `comments`, `commentsState`, `commentsToken`, `commentsCount`; `loadComments()` on first open (not at video start, to save requests), `loadMoreComments()`, `closeComments()`; reset on video change.
4. **View**: new file `Views/Player/MPV/MPVCommentsPanel.swift` (keep `MPVPlayerView.swift` from growing). Row view `MPVCommentRow`. Layout container in `playerBody`: `HStack` or `GeometryReader` with the surface scaled left.
5. Focus: add `FocusTarget.comments` (button) and `.comment(String)`; panel in `.focusSection()`. Update `.onChange(of: focus)` to ignore comment focus for auto-show, update the safety net.
6. Back handling: priority order comments panel → related shelf (plan 2) → controls → leave.
7. Localisation strings; `AppSymbol.comments`.
8. Update `docs/design/tvos-mpv-player-plan.md`.

## Edge cases
- Comment text with emoji/RTL; very long words; zero likes ("0" vs hidden).
- Opening while `videoEnded` / during error: disable the button.
- Next video while the panel is open (autoplay): close panel, reset comments.
- Memory: cap at e.g. 200 loaded comments.

## Acceptance
Panel opens with smooth shrink, video keeps playing with no black flash or engine restart, comments scroll with the remote and page in, Back restores full screen, no focus loss.

## Depends on
Plans 1 and 2 (shared view file and Back priority).
