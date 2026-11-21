# Roadmap — personal build

- **Date:** 2026-11-21
- **Context:** SmartTube is a personal, sideloaded app (never on the App Store). Downloads are
  always on ([ADR-0012](../adr/0012-personal-downloads.md)).

## Constraints

- **No auto-delete.** Nothing is ever removed from the user's library automatically. Storage
  features inform and warn; only an explicit user action deletes a download.
- **Free-account friendly.** Capabilities that need a paid Apple Developer membership (iCloud,
  Push Notifications, Associated Domains, ...) must be switchable **off**, not removed, so the app
  still builds and runs with a free personal team. Prefer local mechanisms (local notifications,
  background app refresh) over server-backed ones.

## Review findings

- Playback has many fallback paths; one test video hit "Stream URLs require decryption" in the
  first client and the chain did not rescue it on the simulator. Matters only with the web player off.
- No background refresh or new-upload notifications existed.
- Doc/tooling drift: `AGENTS.md` pointed to a missing `tasks/README.md`; Smoke/Live test plans are
  missing from the scheme; `swift test` fails to build on macOS; unit tests are order-sensitive
  when run in parallel.
- Download caveats: queued-but-unstarted items are lost on relaunch; expired CDN URLs need Retry.

## Features, in priority order

| # | Feature | Notes |
|---|---|---|
| 1 | **Download management** | Library size + free-space readout and a soft storage warning (no deletion); "Downloaded" badge on cards; audio-only downloads; auto-download Watch Later on Wi-Fi; pause/resume. |
| 2 | **New-upload notifications** | Background app refresh + *local* notifications for subscriptions/RSS. No push, so no paid capability. |
| 3 | **Offline awareness** | Detect no network; open to Downloads and show an offline banner instead of failing feeds. |
| 4 | **Watch-position sync for downloads** | Resume position stored locally; reported to watch history when back online. |
| 5 | **Files export, friendly names** | Human-readable filenames; opt-in export to the Files app. |
| 6 | **Companion server** | yt-dlp fallback ([spec](ytdlp-companion-server.md)); share infrastructure with the existing PO-token service setting. |

Lower value / not planned: CarPlay audio (needs an Apple-approved entitlement).

## Status

See the git log for what has landed; this table is the plan, not a record.
