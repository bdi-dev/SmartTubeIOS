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

## Status (2026-11-21)

| # | Feature | State |
|---|---|---|
| 1 | Download management | Done: used/free readout + low-space note, "Downloaded" badge, audio-only downloads, pause/resume, opt-in auto-download of Watch Later (Wi-Fi only option). No auto-delete anywhere. Auto-download needs a signed-in account to try live; covered by unit tests. |
| 2 | New-upload notifications | Done for locally followed channels **and** the signed-in account's subscriptions (each source has its own silent baseline, so signing in later does not flood alerts). Local notifications, foreground + BGAppRefresh (the background handler reloads the stored session and renews the token). Local channels verified end to end on the simulator; the signed-in source is covered by unit tests only (no account here), and **background refresh only works on a real device**. Brand-account switching is not handled in the background check (primary account's subscriptions). |
| 3 | Offline awareness | Done: opens on Downloads when offline (if something is saved) and shows a banner. |
| 4 | Watch position for downloads | Partly: downloaded videos now get a duration (the scrubber was dead) and resume where you left off. Account-side reporting is **not** done: YouTube ignores watch pings without account-bound tracking URLs, which local files never have. |
| 5 | Files export, friendly names | Done: Share / Save to Files from a download's context menu, named `<title>.mp4/.m4a`. |
| 6 | Companion server | Done through Phase 2: `tools/ytdlp-server/` plus the app side (Settings, server fetcher, Off/Fallback/Always routing). Verified end to end on the simulator against a local server using a fake yt-dlp (byte-identical, playable file). Not verified against real yt-dlp. Phase 3 (delete the server copy after a download, ADR) not done. |

Also done: `scripts/free-account.sh` switches the paid-only iCloud entitlement off without removing it
([how-to](../how-to/free-account-build.md)).

## Planned: NAS

- [NAS status and usage](../superpowers/plans/2026-11-25-nas-status-usage.md): info icon and a Settings sub page.
- [NAS multiple users](../superpowers/plans/2026-11-25-nas-multi-user.md): personal tokens, an admin role and a web admin page, per-user lists with files stored once.
- [NAS HTTPS over Tailscale](../superpowers/plans/2026-11-25-nas-https-tailscale.md): TLS via Tailscale Serve, close the plain HTTP port.
