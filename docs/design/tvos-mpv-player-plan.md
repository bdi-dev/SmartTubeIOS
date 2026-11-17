> status: plan (2026-11-16) — nothing below is implemented yet

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

- **Match content**: set `AVDisplayManager.preferredDisplayCriteria` from the stream's frame rate
  and dynamic range, so 24/25/50 fps video is not judder-converted to 60 Hz.
- **HDR**: HDR variants are ranked last today (`allowHDR: false`). Enable once output is confirmed
  correct through libplacebo/MoltenVK, then add a setting.

## 3. Parity with the standard player

- Autoplay / queue / next-previous (reuse `CurrentQueueStore`).
- Audio-track picker (HLS audio renditions are already parsed in `HLSMasterPlaylist`).
- Chapters on the scrubber; related videos at end-of-video.
- Sleep timer, stats-for-nerds, like/dislike — each small once `PlaybackSession` (WS5) exists.

## 4. tvOS polish

- A UI test target file for the mpv player (`--uitesting-enable-mpv-player` +
  `--uitesting-deeplink-video=<id>` already exist; the file must be added in Xcode).
- Scrub preview thumbnails (storyboards are in the player response).
- Top Shelf "Continue Watching" from `VideoStateStore`.

## 5. Extractor (`InnerTubeKit`)

- The iOS client now answers SABR-only, which breaks the AVPlayer path on tvOS. Either make the
  visionOS client the tvOS default there too, or make mpv the default once §1 passes.
- Apply a PoToken to `rqh=1` adaptive URLs so mpv can open direct streams, not only HLS variants.
- Move the WebKit resolvers into the planned `StreamResolver` target (WS8).

## Decide before making mpv the default

App size (≈30 extra frameworks in the tvOS app) and whether a second player UI is worth keeping,
versus retiring the AVPlayer path on tvOS entirely.
