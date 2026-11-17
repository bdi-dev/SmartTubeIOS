---
status: proposed
date: 2026-11-16
deciders: maintainer
---
# 0010. The stream extractor lives in its own package target, `InnerTubeKit`

## Context and problem statement

`SmartTubeIOSCore` mixed two things with very different change rates: the InnerTube API, client
profiles, PoToken/BotGuard and HLS manifest parsing (rewritten whenever YouTube changes something)
and the app's own view models, stores and settings (changed when the product changes). Nothing
stopped the first from reaching into the second, so a YouTube-side fix could not be reasoned about,
tested, or lifted from another client (yt-dlp, NewPipe, Android SmartTube) in isolation.

## Decision

Move the extractor into a new SwiftPM target and library product, `InnerTubeKit`
(`SmartTubeIOS/Sources/InnerTubeKit/`): `InnerTubeAPI*`, `InnerTubeClients`, `InnerTubeModels`,
`BotGuardClient`, `YouTubeClientCredentials`, the HLS parsers, and the wire models they return
(`Video`, `VideoGroup`, `VideoFormat`, `CaptionTrack`, …). It has no dependencies and the compiler
now rejects any import of app state from it. `SmartTubeIOSCore` depends on it and re-exports it
(`@_exported import InnerTubeKit`), so existing `import SmartTubeIOSCore` call sites are unchanged;
members Core needs across the boundary are `package`, not `public`.

## Consequences

- Good: one directory to patch when YouTube changes; it builds and tests without the UI target.
- Good: behaviour-neutral — a file move plus access modifiers. Same unit-test results before/after.
- Bad: tests that reach extractor internals need `@testable import InnerTubeKit` as well.
- Bad: the WebKit-based resolvers (`YouTubeWebViewHLSExtractor`, `BotGuardWebViewRunner`,
  `YouTubeNDescrambler`, `YTHLSProxyLoader`) are still in the UI target; they need WebKit/AVFoundation
  and remain WS8's planned `StreamResolver` target.

## Alternatives considered

- **A separate package directory**: rejected for now — `package` access does not cross packages, so
  every shared member would have to become `public`, for no extra isolation.
- **Leave it in Core and police imports by convention**: that is the state this replaces.
