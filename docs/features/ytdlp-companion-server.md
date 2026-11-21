# Feature spec — yt-dlp companion server (download fallback)

- **Status:** proposed, not started
- **Date:** 2026-11-21
- **Scope:** personal sideloaded build only (same constraint as [ADR-0012](../adr/0012-personal-downloads.md))
- **Related:** [ADR-0010](../adr/0010-innertubekit-extractor-target.md) (extractor), [ADR-0012](../adr/0012-personal-downloads.md) (downloads)

## 1. Summary

Add a second download *source*: a small HTTP service running yt-dlp on the user's always-on
machine. When the in-app extractor cannot produce a downloadable stream (YouTube changed
something, a video is restricted), the app asks the server to fetch the video, then downloads
the finished MP4 from the server through the **existing** background-session queue. The result
lands in the same Downloads tab as any other download.

## 2. Why, and why not on-device

The native extractor (`InnerTubeDownloadFetcher`) currently works, so this is **insurance for the
day it breaks**, plus a way to get formats the native picker doesn't choose. It is not urgent;
build it when the native path first fails for a video the user cares about (or when quality
becomes a complaint).

yt-dlp is **not** embedded in the app. It needs a Python runtime, ffmpeg, and (for YouTube) a
JavaScript runtime for challenge solving, and it must be updated whenever YouTube changes. On a
server that is `pip install -U yt-dlp`; inside an app bundle it is a new release every time.

## 3. Goals / non-goals

**Goals**
- Reuse the queue, background `URLSession`, relaunch recovery, store and Downloads UI unchanged.
- Fall back automatically only when native resolution fails; never silently when offline.
- Server holds no accounts; single shared token; reachable only on the user's private network.

**Non-goals**
- On-device yt-dlp / Python. Playlists. Subtitles/chapters. Public hosting. Multiple users.
- Streaming playback through the server (downloads only).

## 4. Architecture

```
App (VideoDownloadService queue)
  └─ DownloadFetching  ──►  FallbackDownloadFetcher
        ├─ primary:  InnerTubeDownloadFetcher   (today)
        └─ fallback: YtDlpServerFetcher         (new)
                         POST /v1/jobs, poll status
                         returns DownloadPlan{ parts:[.muxed → server file URL] }
Bytes: BackgroundTransferring (existing background URLSession) ──► server /v1/files/<id>.mp4
Finish: assemble() passthrough-remux (existing) → store.finalize (existing)
```

The key property: a server file is just a one-part (`.muxed`) `DownloadPlan` whose URL points at
the server. Everything downstream already handles that case.

## 5. Server

**Location:** `tools/ytdlp-server/` (new top-level folder; not part of the Xcode project).
**Stack:** one Python file (FastAPI + uvicorn) shelling out to the `yt-dlp` binary as a subprocess
(not as a library, so updating yt-dlp never needs a code change). Requires `ffmpeg`; check
yt-dlp's current docs for the JavaScript runtime it needs for YouTube and install that too.

**Format selection** (AVPlayer-friendly, hardware-decodable H.264 + AAC in MP4):

```
-f "bv*[vcodec^=avc1][height<=?{maxHeight}]+ba[ext=m4a]/b[ext=mp4]/bv*+ba/b"
--merge-output-format mp4 --postprocessor-args "ffmpeg:-movflags +faststart"
```

`faststart` puts the moov atom first so the app's passthrough remux is a no-op-sized step.

**API** (all except `/health` require `Authorization: Bearer <token>`):

| Method & path | Behaviour |
|---|---|
| `GET /v1/health` | `{ok, ytdlpVersion}`; used by the app's "Test connection" button. |
| `POST /v1/jobs` body `{videoId, maxHeight?}` | Idempotent per `videoId`. Returns `202 {status}`; existing job/file returns current state. |
| `GET /v1/jobs/{videoId}` | `{status: queued\|running\|ready\|failed, progress?, error?, fileSize?}` |
| `GET /v1/files/{videoId}.mp4` | The finished file. Must support `Range` and `Content-Length` (background sessions resume with ranges). |
| `DELETE /v1/files/{videoId}` | Optional cleanup; the app calls it after a successful finalize. |

**Rules**
- Validate `videoId` against `^[A-Za-z0-9_-]{11}$` before it touches a path or a command line.
  Pass arguments as an argv array, never through a shell.
- At most 2 concurrent yt-dlp jobs (mirror `DownloadTuning.maxConcurrent`).
- Retention: delete files after 24 h or when the app calls `DELETE`; cap total disk use.
- Optional `cookies.txt` on the server for age-restricted/members content; cookies never leave it.
- Log video IDs and statuses only; no tokens.

## 6. App changes

All new Swift follows `.claude/rules/swift.md` (Swift 6 strict concurrency, `@MainActor @Observable`
view models, `os.Logger`, no Combine/`DispatchQueue`). Core stays Foundation-only.

1. **`DownloadPlan.Part` gains `headers: [String: String]`** (default empty) so the bearer token
   rides on the background-session request. Decode tolerantly: existing `job.json` files have no
   such key and must still load.
2. **`YtDlpServerFetcher: DownloadFetching`** (`Services/`). `resolve(video:)` POSTs the job, then
   polls `GET /v1/jobs/{id}` until `ready` and returns the one-part plan. `assemble` reuses the
   muxed path. Polling uses the existing `BackgroundWorkScope` and is idempotent, so if the app is
   killed mid-poll, relaunch recovery simply resolves again and gets the same job.
3. **`FallbackDownloadFetcher: DownloadFetching`** wraps primary + fallback. Falls back only for
   extraction failures (no streams, decryption/PoToken errors); never for cancellation, offline,
   or a server not configured.
4. **`DownloadJob.source`** (`native` / `server`, default `native`) so a retry reuses the right
   source and the UI can say where a file came from.
5. **Settings → Downloads → "Download server"**: URL, token (stored in Keychain, not
   `AppSettings`), "Test connection" (calls `/health`), and a mode picker:
   *Off* / *Fallback only (default)* / *Always use server*.
6. **Transport security:** prefer HTTPS via `tailscale serve`. If plain HTTP on a tailnet/LAN is
   used instead, add a narrowly scoped ATS exception for that host in the iOS target's Info.plist.

## 7. Failure handling

| Situation | Behaviour |
|---|---|
| Native fails, server not configured | Row fails with the native error (unchanged). |
| Native fails, server unreachable/401 | Row fails: "Download server unavailable"; Retry available. |
| yt-dlp fails on the server | Row fails with the server's `error` string, trimmed. |
| App killed mid-poll | Relaunch recovery re-resolves; server job is idempotent. |
| App killed mid-transfer | Existing background-session reattach (verified for native downloads). |
| Server file removed before transfer | 404 → row fails; Retry re-posts the job. |

## 8. Testing

- **App unit tests (Swift Testing, no live network):** fake server client behind a protocol or a
  `URLProtocol` stub. Cover: queued→running→ready polling; failed status; 401; fallback triggers
  only on extraction errors; fallback skipped when server mode is Off; tolerant `job.json` decode
  with and without `headers`/`source`.
- **Server tests (pytest):** a fake `yt-dlp` executable on `PATH`; cover idempotent POST, bad
  `videoId` rejection, auth, `Range` responses, retention sweep.
- **Manual:** kill the server mid-job; kill the app mid-poll and mid-transfer; download a video the
  native path cannot (to be found when one fails); 10-hour video over the tailnet.

## 9. Rollout

| Phase | Deliverable | Done when |
|---|---|---|
| 0 | Server + `curl` walkthrough in its README | `curl` can post a job and fetch a playable MP4 over the tailnet |
| 1 | `YtDlpServerFetcher`, `headers`, Keychain + Settings UI | "Always use server" downloads a video end to end |
| 2 | `FallbackDownloadFetcher`, `DownloadJob.source`, failure strings | Forced native failure transparently falls back; tests green |
| 3 | Retention, `DELETE` after finalize, docs (ADR-0013 + how-to) | Server disk use stays bounded; docs merged |

## 10. Open questions

- Pin yt-dlp, or auto-update daily? (Leaning: auto-update, with `/health` surfacing the version.)
- Quality default: cap at 1080p, or best available?
- Should the server also report a title/thumbnail for videos the native path couldn't read?
  (The app already has metadata from the card it was started from, so likely no.)
- Which host runs it, and is Tailscale already on it and the phone?
