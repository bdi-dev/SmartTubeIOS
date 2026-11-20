# 08 - Sidebar: wrong item focused at launch, light-mode highlight unreadable

## Goals
1. On launch Home is the selected section, but the navbar's focus cursor sits on "Search" while Home is highlighted.
2. In light mode the focus highlight on navbar items is hard to read.

## Current code (`SmartTubeIOS/Views/Home/TVSidebarRootView.swift`)
- `@FocusState focusedItem`, `contentFocused`, `.defaultFocus($contentFocused, true)`, the `.onChange(of: focusedItem)` correction (`focusCameFromContent`), `selection`.
- The rail collapses to 120 pt; expanded 380 pt.

## Plan
1. Reproduce 1 in the tvOS simulator (fresh launch, look at which row has the platter/cursor, and at what point it lands on Search: the first time the sidebar gains focus, or immediately). Fix so any entry to the sidebar lands on the selected row (Home at launch). Note: `defaultFocus`/`prefersDefaultFocus` are ignored for directional moves; the existing correction in `onChange(of: focusedItem)` may need to cover the launch case, or the sidebar may be getting initial focus when it should not. Find the actual cause before patching.
2. Light mode: render the sidebar in light appearance (simulator appearance, or `.preferredColorScheme(.light)` in a preview/UI test) and compare the focused row with Apple's tvOS sidebar/tab bar light appearance. Use semantic colors and system focus styles rather than custom colors; make focused text/icon contrast clearly readable, and keep the selected-but-unfocused state distinguishable from focused.
3. Check dark mode did not regress. Update or add UI tests (`TVSidebarSettingsUITests`) for the launch focus case.

## Done when
Launch focus test passes, light and dark screenshots of focused and selected rows are attached, existing sidebar UI tests pass.

## Ground rules (all plans)
- Repo: `/Users/ian/Development/SmartTubeIOS`, branch `feat/tvos-mpv-extractor-split`. Read `docs/design/tvos-styling-guide.md` first: Apple tvOS HIG and standard behaviour beat hard-coded numbers in this plan.
- Never push, never open a PR. Commit only your own files (`git add <paths>`), message ending with `Co-Authored-By: Claude Haiku 4.5 <noreply@anthropic.com>`.
- Leave the temporary `[WATCHDIAG]` / `[CHANDIAG]` logging in place.
- Build/test with your own derived data (`-derivedDataPath ~/DevTemp/smarttube/derived-data/<your-name>`) and a cloned tvOS simulator; do not touch the shared simulator. Unit tests: scheme `SmartTubeIOS-Package`, a tvOS Simulator destination by id. UI tests with XCUIRemote live in `SmartTubeApp/UITests/`.
- Do not claim something works unless a test or simulator run showed it. Report what you could not verify.

