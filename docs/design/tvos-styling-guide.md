# tvOS styling guide

Scope: the tvOS UI in `SmartTubeIOS/Sources/SmartTubeIOS/Views`. For every topic the Apple rule
(tvOS Human Interface Guidelines, standard SwiftUI/tvOS behaviour) comes first and the app value
second. Apple wins wherever a number here disagrees with the system: prefer system components,
focus effects, semantic fonts, materials and safe areas, and add a custom value only where the
system gives no answer.

Reviewed against code and simulator screenshots (Apple TV 4K simulator, signed out, plus a
temporary channel gallery harness that was not committed). Before/after images are in
`docs/design/tvos-styling-shots/`.

## Rules

### Focus treatment
- Apple: use the system focus effect for the control type. `.plain` button style is the poster
  effect (about 1.1x lift and shadow) and is for artwork. `.card` is for card-like content.
  List/Form rows get the row platter, clipped to the row. Do not mix a custom treatment on top
  of a system one. Focused items must have room to grow (no clipping).
- App: three treatments exist on purpose. (1) System list/row platter for any row of text
  (Settings, channel list, pickers): use `List`/`Form` with `Button` rows, no custom background.
  (2) System `.card` for shelves (player related shelf). (3) One custom treatment for the sidebar
  rows (`TVSidebarRowStyle`: rounded fill, white at 0.92 when focused, black text). Video grid cards
  use a custom glow (see deviations).
- Never put `.buttonStyle(.plain)` on a full-width row. This was the cause of the oversized
  channel highlight.

### Safe areas
- Apple: keep content inside the title/action safe area, 80 pt left/right and 60 pt top/bottom.
  Chrome that is purely a background may extend to the edge.
- App: content respects the system safe area. The sidebar rail ignores the leading safe area on
  purpose (`TVSidebarRootView`), with its icons 40 pt from the screen edge. Player overlays use
  80 pt horizontal and 60 pt vertical padding (`MPVPlayerView`).

### Sidebar
- Apple: sidebar/tab bar items are icon plus label, a highlight hugging the row, same padding on
  both sides, labels in a semantic body style.
- App (`TVSidebarLayout`): collapsed rail 120 pt = 24 inset + 72 pill (40 pt icon, 16 pt padding
  each side) + 24 inset, so the icon is centred in its pill and left and right gaps are equal.
  Expanded sidebar 380 pt, pill fills the inner width (332 pt). Content gap 56 pt. Row text is a
  fixed 30 pt semibold (should become `.title3` or `.body`; see recommendations).
  Root cause of the previous wide pill: rows had no explicit width, so the pill stretched to the
  rail's inner edge while the left side had 40 pt and the right 16 pt.

### Cards (video grid)
- Apple: focusable cards scale about 1.05-1.1 with the system shadow; leave at least 40 pt between
  items so the scaled card does not cover a neighbour; 16:9 thumbnails, text below.
- App: 4 columns, `videoGridRowSpacing` = 40 pt on tvOS, thumbnail corner radius 8, scale 1.08.

### Typography
- Apple: use semantic Dynamic Type styles. tvOS sizes: body 29, callout 31, subheadline 29,
  headline 38, title3 38, caption/caption2/footnote 23. Do not go below 23 pt.
- App: use `.title3`/`.headline` for titles and controls, `.callout`/`.subheadline` for text,
  `.caption` only for metadata. Fixed `.system(size:)` only for hero symbols and the sign-in code.

### Spacing, radii, motion
- Apple: consistent spacing scale; system corner radii on system controls; short ease animations.
- App: spacing 8 / 12 / 16 / 24 / 40 (40 between focusable grid items). Radii: 16 for rows,
  panels and pills (sidebar row, comments panel), 8 for thumbnails, capsule for chips. Focus
  animation 0.15 s ease, panel/overlay transitions 0.2-0.25 s ease in/out.

### Colours and materials
- Apple: use system materials and semantic colours so Light and Dark both work; keep text
  contrast on focused (light) platters.
- App: `.ultraThinMaterial` for the sidebar, `Color.primary`/`.secondary` for text,
  black scrims with gradients over video. Accent only for progress and selection.

## Deviations found

| Location | What | Severity | Status |
|---|---|---|---|
| `Views/Channel/ChannelListView.swift` (tvOS body) | Channel rows were `.plain` Buttons in a ScrollView with an extra grey background: poster focus (scale and lift) on a full-width row, platter taller than the row and overlapping neighbours | High | Fixed (5a8e443) |
| `Views/Home/TVSidebarRootView.swift` `TVSidebarLayout`, `row` | Collapsed pill 90 pt wide (icon not centred), 40 pt left vs 16 pt right gap; expanded sidebar 440 pt with large empty space after labels | High | Fixed (8c7bee5) |
| `Views/Browse/VideoCardView.swift:377-378` | Custom white glow (0.9 opacity, radius 18) plus 1.08 scale instead of the system effect; very bright on a dark UI | Medium | Recommend |
| `Views/Channel/ChannelView.swift:186-189` | tvOS grid uses 12 pt spacing; focus scale 1.08 overlaps neighbours (rest of the app uses 40) | Medium | Recommend: use `videoGridRowSpacing` |
| `Views/Common/LibraryView.swift:105-106` | `.borderless` style plus manual `scaleEffect(1.12)` and an own fill: mixes system and custom focus, scale above 1.1 | Medium | Recommend |
| `Views/Search/SearchView.swift:104,116,240,246,282,286` | `.buttonStyle(.plain)` on small icons and on List rows: poster effect on rows, no clear focus on icons | Medium | Recommend: drop `.plain` on rows, use default/borderless |
| `Views/Search/SearchView.swift` `FilterChip` | `.caption`/`.caption2` capsule with a nested Button, small focus target | Medium | Recommend |
| `Views/Search/SearchView.swift` search bar | Hand-built text field with `cornerRadius: 10` and 10 pt padding; not the system tvOS search | Low | Recommend (`.searchable`) |
| `Views/Common/ChannelSwitcherView.swift:82`, `Views/Settings/SettingsView.swift:569,595` | `.plain` Button in a List row; renders as the system row platter (checked in screenshot), harmless but redundant | Low | Recommend |
| `Views/Home/TVSidebarRootView.swift` `TVSidebarRowStyle` | Fixed 30 pt font, custom 0.92 white fill | Low | Recommend: semantic font |
| `Views/Browse/VideoCardView.swift` card layout | Thumbnail radius 8 and badges 3 pt; radii differ from sidebar 16 | Low | Recommend: one radius scale |
| `Views/Player/MPV/MPVCommentsPanel.swift:45-46` | Panel uses 40 pt horizontal padding inside a trailing column; text starts close to the edge | Low | Recommend: 80 pt outer inset on the screen edge side |
| `Views/Player/MPV/MPVPlayerView.swift:157` | Bottom padding 70 where the rest of the overlay uses 60 | Low | Recommend |
| `Views/Common/SignInView.swift` tv layout | Opaque black 0.85 backdrop and fixed `.system(size: 56)` code; fine for a code screen, but backdrop ignores Light mode | Low | Recommend: material |
| `Views/Settings/SettingsPicker.swift` | Standard List/Button rows with a checkmark: consistent with Settings | None | OK |

## Recommendations (not done)

1. Replace the custom card glow with the system effect: either `.buttonStyle(.card)` on the card
   (needs its tap/long-press handling re-verified) or at least lower the glow and keep 1.05 scale.
2. Give `ChannelView`'s tvOS grid the same spacing constant as `VideoGridSection`.
3. Rebuild the Library chip bar and Search filter chips with one chip style (system
   `.bordered`/`.borderedProminent` capsule), no manual scale.
4. Move the sidebar row font to a semantic style and, if desired, a shared `TVStyle` constants
   file for spacing (8/12/16/24/40) and radii (16/8). Not added now: only the sidebar and a few
   views would use it, so it would not remove real duplication yet.
5. Use `.searchable` for tvOS Search.
6. Verify on device: Light appearance for the sidebar material, and the player scrims over bright
   video.

## Verification notes

- Verified in the Apple TV simulator: collapsed and expanded sidebar (frame widths 120 and 380),
  channel list focus before and after, channel switcher row (system platter, unchanged).
- Not verified: real Apple TV (overscan, brightness), Light appearance, a signed-in account row
  with an avatar, long channel names in the expanded sidebar.
