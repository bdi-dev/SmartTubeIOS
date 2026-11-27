# NAS status and usage — feature plan

> Status: ready to build (updated for the multi-user server).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.

## Goal
Show what the NAS (yt-dlp companion server) is doing and how full it is, without leaving the
app: a quick **info icon** beside the "Available on NAS" header, and a fuller **NAS** sub page in
Settings. Mostly read-only; the unkept cap (default 20 GB) is shown but only an admin can change it, on the web admin page. Nothing
here deletes anything directly (see [the roadmap](../../features/roadmap.md)).

## What the user sees
**Info icon (Downloads tab).** An `info.circle` button beside the "Available on NAS" header opens
a sheet with the same summary as the Settings page, plus a "Refresh" action.

**Settings > NAS sub page.** Rows:
- Connection: server URL host, reachable or not, last checked time, round trip.
- Server: API version, yt-dlp version, server uptime.
- Your usage: your own video count, kept and unkept bytes, against your cap.
- Storage: disk free and total for the data volume; kept bytes and count; unkept bytes and count
  against the cap (a gauge, e.g. "12.4 of 20 GB"); a warning colour above 90% of the cap.
- Unkept cap: shown read-only, with a note that an admin sets it. Admins change it on the web admin
  page, where saving warns that unkept files over the new cap are evicted oldest first.
- Activity: jobs running and queued; the last 5 failures with video id and short reason.

## Server work (`tools/ytdlp-server/server.py`)
Built on the multi-user server (API version 4; see [multiple users](2026-11-25-nas-multi-user.md)).
1. Add `GET /v1/status` (any valid personal token). Bump `API_VERSION` to 5. Response is scoped to
   the **caller**, plus shared server facts:
   `{ apiVersion, ytdlpVersion, uptimeSeconds, disk: {freeBytes, totalBytes},
   you: {videoCount, kept: {count, bytes}, unkept: {count, bytes}, capBytes},
   jobs: {running, queued}, recentFailures: [{videoId, message, at}] }`.
   - `you` reuses the per-profile usage the server already computes (a shared video counts in full
     toward each owner, so `you.unkept.bytes` can exceed what the file costs on disk).
   - `jobs` counts only jobs the caller owns; `recentFailures` lists only the caller's failures.
   - Admins also get `server: {profiles, totalFiles, totalBytes}` (physical files on disk, each
     counted once). Normal users never receive it. No titles or other users' ids are ever returned.
2. `capBytes` comes from the caller's profile. There is no cap-setting endpoint in this plan.
3. Disk numbers from `shutil.disk_usage(config.data_dir)`. Cache the shared parts (disk, ytdlp
   version) for 10 seconds; per-user numbers are computed per request.
4. Keep a bounded in-memory ring (20 entries per profile) of recent job failures. It resets on
   restart; say so in the README.
5. The `/admin` page shows the same status for the admin (disk gauge, server totals, jobs, recent
   failures) in a "Server" panel above the users table. It reuses `/v1/status`.
6. Tests in `tests/test_server.py`: empty store; mixed kept/unkept; a shared video counts toward both
   owners; user B never sees user A's failures or jobs; a normal user gets no `server` block and an
   admin does; cap exceeded; failure ring is bounded and per profile; 401 without a token; an old
   app still works (`/v1/status` is new, nothing else changes).
7. README: document `/v1/status` and the failure-ring reset. Do not redeploy from the agent. When
   redeploying stack 42, embed `server.py` **gzipped** (see the README deploy note).

## App work
1. `YtDlpServerStatus` Codable model and `YtDlpServerClient.status()` in the same style as `me()`
   (`SmartTubeIOSCore` model, Foundation-only). Treat a 404 as "server too old" and show a hint to
   update it. A 401 reuses the existing "Token revoked or wrong" state.
2. `NASStatusViewModel` (`@MainActor @Observable`): `load()`, `refresh()`, a state enum
   (`loading`, `loaded`, `unreachable(message)`, `serverTooOld`, `rejected`), and a "stale"
   timestamp. No background polling; refresh on appear and on pull to refresh.
3. `NASStatusView` shared by both entry points; the sheet wraps it in a `NavigationStack`, the
   Settings page pushes it. Never nest `NavigationStack`s. Shows the rows above using the
   caller-scoped `you` block; an admin additionally sees the `server` totals.
4. Both entry points are read-only; the cap is displayed, not edited, with the "an admin sets it" note.
5. Info icon in the Downloads header (`AppSymbol.info`) and a Settings row (`SettingsView+NAS.swift`
   or a new file; the "Signed in as" row already lives in `SettingsView+Downloads.swift`) shown only
   when a yt-dlp server URL and token are configured.
6. Identifiers in `AccessibilityID.Downloads` / `.Settings`; symbols in `AppSymbol`.
7. Unit tests with a fake client for each state; byte formatting reuses `formatByteCount`.

## Non-goals
- No other server controls, no delete-from-this-screen, no yt-dlp self-update, no push alerts.
- No history charts; a single snapshot is enough.

## Open questions
- None. Per-user usage and the admin view are decided above.
