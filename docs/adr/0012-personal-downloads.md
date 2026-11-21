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
via `Video.localFileURL`, never the web player. Downloads run in the foreground only; a background
`URLSession` was assessed and deferred.

## Consequences

- Good: offline playback with no new player code.
- Bad: not submittable to the App Store as-is; shipping to the store would need the `#if` gating
  restored (`git show 117448c^` has the previous form).
- Bad: downloads pause when the app is suspended; interrupted ones are marked failed and can be retried.

## Alternatives considered

- Keep downloads compiled out: no offline library.
- Export to Photos: pulls in Photos permissions and loses per-video metadata.
