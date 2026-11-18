# Plan 4 — Home screen rework (sidebar + content grid)

## Goal
Replace the tvOS top-tab + chip-bar Home with a **left sidebar** (YouTube-TV-like) and a **content grid** on the right. Owner decision: sidebar + grid (not hero+shelves).

## Existing pieces
- `Views/RootView.swift`: `MainTVTabView` = top `TabView` over `AppSection` (`home, search, library, settings`), each in a `NavigationStack`.
- `Views/Home/HomeView.swift` (large): chip bar over `BrowseSection`s; "Home" chip = multi-shelf overview via `HomeViewModel`; other chips = full feed via `BrowseViewModel`. Has tvOS-only `@FocusState focusedSection`. Also holds shorts presentation, channel destination, subscriptions channel filter, sign-in sheet.
- `Views/Browse/VideoCardView.swift`, `ShortsRowSection`, `ThumbnailFillView`, `BrowseView`.
- iOS/macOS share `HomeView`; **do not regress iOS**. All tvOS changes under `#if os(tvOS)`, or a new tvOS-only file.

## Target design
- **Sidebar** (≈ 300 pt, collapsible to icons ≈ 100 pt when focus is in the grid): items in this order: Search, Home, Subscriptions, Trending (if enabled), History, Playlists, Shorts (if not `hideShorts`), Settings, then Account (avatar + sign in/out). Source of truth: `store.settings.enabledSections` via `BrowseSection` (see `visibleSections` in `HomeView`), plus Search and Settings from `AppSection` (no single Library item). Selected item highlighted; focused item uses the system focus effect.
- **Grid**: `LazyVGrid`, 4 columns at 1920×1080 (card ≈ 400×225 + 2-line title + channel/meta), adaptive columns, 40 pt spacing, safe-area insets. Infinite scroll with the existing "load more" triggers (`needsMoreNonShorts` etc.). Pull current focus preservation: when returning from the player, focus returns to the card that was opened.
- "Home" section = flat grid of recommended videos. No "Continue watching" row (owner decision).
- Shorts section keeps `ShortsRowSection` behaviour (rows), not grid.
- Subscriptions: keep channel filter (`subscriptionsChannelFilter`) as a horizontal avatar strip pinned at the top of the grid, focusable.
- Header inside the content area: section title + (when relevant) a refresh button. No top tab bar.
- Empty/loading/error states: skeleton cards while loading; "Sign in to see subscriptions" panel with button when signed out.
- Focus rules: Left from the grid's first column moves to the sidebar; Right from the sidebar moves to the grid (restores last focused card). Menu/Back from the grid → focuses the sidebar; Back from the sidebar → system default (exit app).

## Architecture
1. New tvOS-only container `TVRootView` (file `Views/Home/TVSidebarRootView.swift`) replacing `MainTVTabView` in `RootView` (`#if os(tvOS)`): `NavigationSplitView` is **not** recommended on tvOS for custom behaviour; build with `HStack { TVSidebar(...); content }` and `.focusSection()` on each, `@FocusState` for sidebar items, `@Namespace` + `prefersDefaultFocus` for restore.
2. Selection model: `enum TVDestination { search, section(BrowseSection), history, playlists, settings, account }`; `@SceneStorage`/`@State selection`. Content `switch` renders: `SearchView`, `TVFeedGridView(section:)`, the existing history and playlists views (see `LibraryView` for how they are built), `SettingsView`.
3. New `TVFeedGridView` wraps `BrowseViewModel` (reuse its loading, pagination, auth). Do **not** fork the view models; read how `HomeView` drives `sectionVM`/`homeVM` and extract the minimal shared loader if required (small refactor allowed; keep iOS behaviour identical and run the iOS build).
4. Navigation to the player/channel/playlist stays as today (`NavigationStack` inside the content column, or the existing deep-link mechanism; check how `MPVPlayerView` is presented on tvOS — fullScreenCover vs. push — and keep it).
5. Sidebar collapse: width animates when focus enters/leaves; content grid reflows only once (don't animate column counts per frame — fix grid width at the collapsed size and let the sidebar overlay, like the Apple TV app).
6. Settings and Search keep their current views for now (separate polish plans).
7. Accessibility identifiers for every sidebar item (`tv.sidebar.<name>`) and the grid (`tv.grid`), so a UI test can be added later.
8. Strings and `AppSymbol` additions (history, subscriptions icons may already exist — grep first).

## Steps
(No owner questions remain.)
1. Read `HomeView.swift`, `RootView.swift`, `BrowseViewModel`, `HomeViewModel` fully; list what the chip bar does that the sidebar must keep (write the list in the commit message).
2. Build the sidebar + empty content, wire selection, verify focus movement in the Simulator.
3. Plug in `TVFeedGridView` for Home/Subscriptions/History/etc. (Playlists reuse the existing playlists view.) Verify paging and focus restoration after playing a video.
4. Account/sign-in entry (existing `showSignIn` flow).
5. Remove the tvOS chip bar from `HomeView` (`#if !os(tvOS)`), keep iOS untouched.
6. Polish: focus effects, scroll-to-top on re-select of the active sidebar item, loading skeletons, empty states.
7. Docs update; screenshots from the Simulator into `docs/design/tvos-next/screenshots/` (optional).

## Owner decisions on the open questions (resolved)
- Home is a plain recommended-videos grid. **No** "Continue watching" row.
- Library is **split** into separate sidebar items: History and Playlists (each opens its existing content directly). Drop the single Library entry on tvOS.
- Appearance follows the system light/dark setting; do not force dark.

## Acceptance
Sidebar with all enabled sections; Left/Right/Back focus rules above; grid pages smoothly to ≥100 items without hitches; opening a video and closing it returns focus to the same card; iOS and macOS targets still build and look unchanged.

## Risks
Largest change in the set; focus restoration across `NavigationStack` pushes is fragile on tvOS. Land behind a settings flag (`useSidebarHome`, default true on tvOS) for the first device test so the old tab UI can be restored quickly.
