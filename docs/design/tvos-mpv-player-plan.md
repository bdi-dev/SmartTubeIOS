> status: in progress (2026-11-18) — §2–§4 partly implemented; items marked **done** need a real Apple TV to confirm

# tvOS mpv player — next steps

Follows ADR-0010 (`InnerTubeKit`) and ADR-0011 (opt-in mpv engine). The engine plays and is
remote-tested in the Simulator; this is what stands between that and making it the tvOS default.
Ordered by what unblocks the most.

## 1. Verify on a real Apple TV (blocks everything else)

- **Back/Menu**: hides the controls, then leaves the player. Never exercised — the Simulator
  tooling used so far cannot send it.
- **Hardware decode**: does VP9 actually decode in VideoToolbox on tvOS 26.2+? The engine assumes
  so and steps down if not; confirm with the stream badge ("Hardware" vs "Software") at 4K60.
- **Dropped frames** at 1080p60 and 2160p60, H.264 and VP9; memory with the 96 MiB cache.
- **SponsorBlock auto-skip** on a video with a `sponsor` segment (only the manual button is tested).

## 2. Picture quality on a TV

- **Match content — done, unverified:** `applyDisplayCriteria()` sets
  `AVDisplayManager.preferredDisplayCriteria` from the stream's frame rate and dynamic range at
  first frame, and clears it on exit. It only takes effect with "Match Content" on in tvOS
  settings; the Simulator cannot show it.
- **HDR:** HDR variants are ranked last today (`allowHDR: false`). Enable once output is confirmed
  correct through libplacebo/MoltenVK, then add a setting.

## 3. Parity with the standard player

- **Done:** previous/next buttons and autoplay (Current Queue, shuffle, suggestions; honours the
  autoplay setting); up-next row at end of video; chapter ticks, title and menu (no chaptered video
  was available to test with); audio-language menu for multi-audio uploads (unit-tested, not seen
  on screen).
- **Extractor fix:** the signed-out `/next` response now carries no `compactVideoRenderer`, so
  suggestions came back empty; `InnerTubeAPI+Social` falls back to the end-screen videos.
- Still open: sleep timer, stats-for-nerds, like/dislike — each small once `PlaybackSession` (WS5)
  exists; audio languages for HLS-only videos (renditions are parsed in `HLSMasterPlaylist`).

## 4. tvOS polish

- **UI test file** for the mpv player — must be added in Xcode. `--uitesting-enable-mpv-player`,
  `--uitesting-deeplink-video=<id>` and `--uitesting-keep-controls` (no auto-hide) exist for it.
- **Scrub preview thumbnails:** storyboards are in the player response but `PlayerInfo` does not
  carry them yet — parse `storyboards.playerStoryboardSpecRenderer`, then draw the tile above the
  thumb.
- **Top Shelf "Continue Watching"** from `VideoStateStore` — needs a new extension target, which
  means an Xcode project change.

## 5. Extractor (`InnerTubeKit`)

- The iOS client now answers SABR-only, which breaks the AVPlayer path on tvOS. Either make the
  visionOS client the tvOS default there too, or make mpv the default once §1 passes.
- Apply a PoToken to `rqh=1` adaptive URLs so mpv can open direct streams, not only HLS variants.
- Move the WebKit resolvers into the planned `StreamResolver` target (WS8).

## Decide before making mpv the default

App size (≈30 extra frameworks in the tvOS app) and whether a second player UI is worth keeping,
versus retiring the AVPlayer path on tvOS entirely.
