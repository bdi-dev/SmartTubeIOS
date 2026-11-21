---
status: accepted
date: 2026-11-21
deciders: maintainer
---
# 0012. Downloads are re-enabled for personal sideloaded builds only

## Context and problem statement

Downloading was compiled out behind `ENABLE_DOWNLOADS` (commit 117448c) to avoid App Store
guideline 5.2.3. This build is sideloaded for personal use and never submitted, so that guideline
does not apply, and an offline library is wanted.

## Decision

Remove the `ENABLE_DOWNLOADS` gates. `VideoDownloadService` is a FIFO queue (max
`DownloadTuning.maxConcurrent` running) that writes MP4s to app storage only
(`Documents/SmartTubeDownloads`, excluded from backup); there is no Photos export. `DownloadStore`
keys metadata by YouTube `videoId`, stores a relative `fileName` plus a status, and reconciles
interrupted or missing files at launch. Downloaded files always play through the AVPlayer pipeline
via `Video.localFileURL`, never the web player.

### Background transfers

All CDN bytes travel through one background `URLSession`
(`DownloadTuning.backgroundSessionIdentifier`, `sessionSendsLaunchEvents`, not discretionary), owned
by the long-lived `BackgroundDownloadSession` and hidden behind the `BackgroundTransferring` seam.
Downloads therefore continue while the app is suspended and finish while it is not running.

1. `VideoDownloadService` asks `DownloadFetching.resolve` (foreground, quick) for a `DownloadPlan`:
   one muxed URL, or video + audio URLs, each with the User-Agent that signed it.
2. It persists `Staging/<videoId>/job.json` (expected parts, done parts, URLs, user agents) and
   starts one `URLSessionDownloadTask` per part, tagged `taskDescription = "<part>:<videoId>"`.
3. The nonisolated session delegate moves each finished temp file synchronously into
   `Staging/<videoId>/<part>.tmp` (the system deletes it on return) and forwards ordered events
   through an `AsyncStream` to the `@MainActor` service.
4. When every part is staged, the service runs `DownloadFetching.assemble` (merge if needed, then
   passthrough remux) inside a UIKit background task (`BackgroundWorkScope`, iOS only), then
   `DownloadStore.finalize`, then deletes the staging directory.
5. `application(_:handleEventsForBackgroundURLSession:)` stashes the system completion handler; it
   is invoked once the `urlSessionDidFinishEvents` marker has travelled through the same ordered
   stream, i.e. after post-processing has taken its background task.
6. On launch `DownloadStore.reconcile()` no longer fails in-flight entries. The service calls
   `getAllTasks` and decides per entry: live task -> stay `downloading`; all parts staged ->
   resume post-processing; neither -> `failed("Interrupted")`. Cancel/remove cancels the tasks and
   deletes staging.

Resolved CDN URLs expire (about 6 hours). A transfer that fails (HTTP 403/410 or otherwise) marks the
entry failed with an explanatory message; Retry re-resolves. There is no automatic retry loop.
Items still waiting in the in-memory queue (not yet started) do not survive a relaunch and are failed
as interrupted. A single shared `VideoDownloadService` (from the environment) is the only consumer of
the session's event stream.

## Consequences

- Good: offline playback with no new player code.
- Bad: not submittable to the App Store as-is; shipping to the store would need the `#if` gating
  restored (`git show 117448c^` has the previous form).
- Bad: a merge that is cut short by the OS (background time expiry) resumes only on the next launch.
- Bad: a resolved URL that expires before a queued transfer starts or resumes needs a manual Retry.

## Alternatives considered

- Keep downloads compiled out: no offline library.
- Export to Photos: pulls in Photos permissions and loses per-video metadata.
