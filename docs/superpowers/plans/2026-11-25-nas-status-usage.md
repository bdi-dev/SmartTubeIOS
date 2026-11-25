# NAS status and usage — feature plan

> Status: proposed, not started. Personal-use build only (sideloaded, never submitted).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.

## Goal
Show what the NAS (yt-dlp companion server) is doing and how full it is, without leaving the
app: a quick **info icon** beside the "Available on NAS" header, and a fuller **NAS** sub page in
Settings. Read-only. Nothing here deletes anything (see the no-auto-delete rule in
[the roadmap](../../features/roadmap.md)).

## What the user sees
**Info icon (Downloads tab).** An `info.circle` button beside the "Available on NAS" header opens
a sheet with the same summary as the Settings page, plus a "Refresh" action.

**Settings > NAS sub page.** Rows:
- Connection: server URL host, reachable or not, last checked time, round trip.
- Server: API version, yt-dlp version, server uptime.
- Storage: disk free and total for the data volume; kept bytes and count; unkept bytes and count
  against the cap (a gauge, e.g. "12.4 of 20 GB"); a warning colour above 90% of the cap.
- Activity: jobs running and queued; the last 5 failures with video id and short reason.

## Server work (`tools/ytdlp-server/server.py`)
1. Add `GET /v1/status` (authorised). Bump `API_VERSION` to 3. Response:
   `{ apiVersion, ytdlpVersion, uptimeSeconds, disk: {freeBytes, totalBytes},
   kept: {count, bytes}, unkept: {count, bytes, capBytes}, jobs: {running, queued},
   recentFailures: [{videoId, message, at}] }`.
2. Compute counts and bytes from the sidecars the library already reads; disk numbers from
   `shutil.disk_usage(config.data_dir)`. Cache the result for 10 seconds so polling is cheap.
3. Keep a bounded in-memory ring (20 entries) of recent job failures. It resets on restart; say so
   in the README.
4. Tests in `tests/test_server.py`: empty store, mixed kept/unkept, cap exceeded, failure ring,
   401 without a token.
5. Redeploy stack 42 (same Portainer update as the metadata backfill).

## App work
1. `YtDlpServerStatus` Codable model and `YtDlpLibraryClient.status()` in `SmartTubeIOSCore`
   (Foundation-only). Treat a 404 as "server too old" and show a hint to update it.
2. `NASStatusViewModel` (`@MainActor @Observable`): `load()`, `refresh()`, a state enum
   (`loading`, `loaded`, `unreachable(message)`, `serverTooOld`), and a "stale" timestamp. No
   background polling; refresh on appear and on pull to refresh.
3. `NASStatusView` shared by both entry points; the sheet wraps it in a `NavigationStack`, the
   Settings page pushes it. Never nest `NavigationStack`s.
4. Info icon in the Downloads header (`AppSymbol.info`) and a Settings row (`SettingsView+NAS.swift`)
   shown only when a yt-dlp server URL and token are configured.
5. Identifiers in `AccessibilityID.Downloads` / `.Settings`; symbols in `AppSymbol`.
6. Unit tests with a fake client for each state; byte formatting reuses `formatByteCount`.

## Non-goals
- No auto-eviction controls, no delete-from-this-screen, no yt-dlp self-update, no push alerts.
- No history charts; a single snapshot is enough.

## Open questions
- Should the cap be editable from the app, or stay a server environment variable? (Default: stay.)
- Show per-profile usage once [multiple users](2026-11-25-nas-multi-user.md) lands.
