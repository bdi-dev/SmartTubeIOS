# SmartTube yt-dlp companion server (Phase 0)

A small, **dependency-free** (Python 3.9+ standard library) HTTP service that runs `yt-dlp` on your
always-on machine so the app can fetch videos its own extractor cannot. Design and rollout plan:
[docs/features/ytdlp-companion-server.md](../../docs/features/ytdlp-companion-server.md).

Status: **Phase 0 — the server only.** The app does not call it yet (Phase 1 adds
`YtDlpServerFetcher` and the Settings entries).

## Set up

```bash
pip install -U yt-dlp          # or: brew install yt-dlp
brew install ffmpeg            # needed to merge video + audio and write faststart MP4
# yt-dlp may also need a JavaScript runtime for YouTube; follow yt-dlp's current install docs.

export YTDLP_TOKEN="$(openssl rand -hex 32)"   # the app will send this as a bearer token
python3 tools/ytdlp-server/server.py            # listens on 127.0.0.1:8787
```

Reach it from your phone over Tailscale (`tailscale serve --bg 8787` gives HTTPS) or your LAN
(`YTDLP_HOST=0.0.0.0`). **Do not expose it to the public internet.**

Settings (environment): `YTDLP_TOKEN` (required), `YTDLP_BIN`, `YTDLP_DATA_DIR`, `YTDLP_HOST`,
`YTDLP_PORT`, `YTDLP_MAX_CONCURRENT` (2), `YTDLP_RETENTION_HOURS` (24), `YTDLP_MAX_HEIGHT` (1080),
`YTDLP_COOKIES` (optional cookies.txt for age-restricted/members videos; stays on this machine).

## Try it with curl

```bash
B=http://127.0.0.1:8787; A="Authorization: Bearer $YTDLP_TOKEN"; ID=dQw4w9WgXcQ

curl -s $B/v1/health                                   # {"ok": true, "ytdlpVersion": "..."}
curl -s -X POST -H "$A" -d "{\"videoId\":\"$ID\"}" $B/v1/jobs     # 202 {"status":"queued",...}
curl -s -H "$A" $B/v1/jobs/$ID                         # poll: queued | running | ready | failed
curl -s -H "$A" -o out.mp4 $B/v1/files/$ID.mp4        # download (supports Range)
curl -s -X DELETE -H "$A" $B/v1/files/$ID              # free the disk space
```

## API

| Method & path | Notes |
|---|---|
| `GET /v1/health` | No auth. `{ok, ytdlpVersion}`. |
| `POST /v1/jobs` `{videoId, maxHeight?}` | Idempotent per id. `202` with the job state. |
| `GET /v1/jobs/{id}` | `{status, progress, error?, fileSize?}`; `404` if unknown. |
| `GET /v1/files/{id}.mp4` | The file; `Range` supported (`206`/`416`). |
| `DELETE /v1/files/{id}` | Removes the file and job. |

Safety: ids must match `^[A-Za-z0-9_-]{11}$`; yt-dlp is started with an argument list (never a
shell); files older than the retention window are removed at startup; logs show method and path
only, never tokens.

## Tests

```bash
cd tools/ytdlp-server && python3 -m unittest discover -s tests -v
```

The tests use a fake `yt-dlp` (`tests/fake_ytdlp.py`), so they need no network and no yt-dlp.
