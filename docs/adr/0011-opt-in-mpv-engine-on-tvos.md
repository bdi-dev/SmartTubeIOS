---
status: proposed
date: 2026-11-16
deciders: maintainer
---
# 0011. mpv is an opt-in second player engine on tvOS, not a replacement for AVPlayer

## Context and problem statement

tvOS has no WKWebView, so it cannot use the TOS player or the WebView-based stream resolvers; it
relies on the AVPlayer path, which only opens HLS or MP4 it can compose. When a client profile
returns neither (e.g. the iOS client answering SABR-only), tvOS playback fails outright. libmpv
(MPVKit: FFmpeg + libplacebo over MoltenVK) opens adaptive video + separate audio, WebM/VP9 and
individual HLS variants directly, and sends the User-Agent of the client that signed the URLs.

## Decision

Add mpv as a second engine on tvOS behind `AppSettings.useMPVPlayerOnTV` (default off).
`PlayerScreen` routes each video to `MPVPlayerView` or `PlayerView`. The mpv path has its own small
view model (`MPVPlayerViewModel`) and a pure ranking policy (`MPVStreamSelector`); it does not touch
`PlaybackViewModel` or its cascade. One engine per video: when mpv cannot open a video the user can
reopen it in the standard player from scratch — no mid-stream handoff (same rule as ADR-0007).
MPVKit is linked into the tvOS slice only.

## Consequences

- Good: plays videos the AVPlayer path cannot, picks the stream by what the device decodes
  smoothly, and steps down by itself if a codec assumed to be hardware-decoded is not.
- Good: additive and reversible — the default path is byte-for-byte what it was.
- Bad: a second player UI to maintain; it lacks chapters, queue/autoplay and audio-track selection.
- Bad: + ~30 frameworks in the tvOS app. HDR output, display-mode (frame-rate) matching and
  VideoToolbox VP9 decode are **unverified on hardware** — only the Simulator has been exercised.

## Alternatives considered

- **Replace AVPlayer inside `PlaybackViewModel`**: rejected — ~5k lines of AVPlayer-specific
  recovery logic, each branch a past incident, with no way to prove parity from the Simulator.
- **AetherEngine-style local HLS proxy in front of AVPlayer**: already considered and not adopted
  (`docs/research/AetherEngine.md`); it keeps AVPlayer's codec limits.
