# SmartTube yt-dlp companion server

A small, **dependency-free** (Python 3.9+ standard library) HTTP service that runs `yt-dlp` on your
always-on machine so the app can fetch videos its own extractor cannot. Design and rollout plan:
[docs/features/ytdlp-companion-server.md](../../docs/features/ytdlp-companion-server.md).

Status: server (Phase 0) and app side (Phase 1) are built. In the app: Settings > Downloads >
**yt-dlp server** (Off / Fallback / Always), the server URL, the token (kept in the Keychain) and a
"Test connection" button that also checks the token. *Fallback* tries the app's own extractor first
and only asks the server when that fails; *Always* always asks the server. Use an `https://` address
(Tailscale gives you one); plain `http://` only works for IP addresses such as `127.0.0.1` because of
App Transport Security.

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
`YTDLP_PORT`, `YTDLP_MAX_CONCURRENT` (2), `YTDLP_UNKEPT_CAP_GB` (20; kept downloads have no cap),
`YTDLP_MAX_HEIGHT` (1080), `YTDLP_COOKIES` (optional cookies.txt for age-restricted/members videos;
stays on this machine).

## Try it with curl

```bash
B=http://127.0.0.1:8787; A="Authorization: Bearer $YTDLP_TOKEN"; ID=dQw4w9WgXcQ

curl -s $B/v1/health                                   # {"ok": true, "apiVersion": 2, "ytdlpVersion": "..."}
curl -s -X POST -H "$A" -d "{\"videoId\":\"$ID\",\"title\":\"A video\",\"keep\":true}" $B/v1/jobs   # 202 {"status":"queued",...}
curl -s -H "$A" $B/v1/jobs/$ID                         # poll: queued | running | ready | failed
curl -s -H "$A" -o out.mp4 $B/v1/files/$ID.mp4        # download (supports Range)
curl -s -H "$A" "$B/v1/library?limit=50"               # newest first; pass nextCursor back as &cursor=
curl -s -X PUT -H "$A" -d '{"keep":false}' $B/v1/files/$ID/keep   # unkeep: now subject to the 20 GB cap
curl -s -X DELETE -H "$A" $B/v1/files/$ID              # free the disk space (409 while still downloading)
```

## API

| Method & path | Notes |
|---|---|
| `GET /v1/health` | No auth. `{ok, apiVersion, ytdlpVersion}`; `apiVersion` 2 adds the library, keep and metadata endpoints. |
| `POST /v1/jobs` `{videoId, maxHeight?, title?, channelTitle?, duration?, thumbnailURL?, keep?}` | Idempotent per id; the first POST's metadata wins. `keep` defaults to `true`. `202` with the job state. |
| `GET /v1/jobs/{id}` | `{status, progress, error?, fileSize?}`; `404` if unknown. |
| `GET /v1/files/{id}.mp4` | The file; `Range` supported (`206`/`416`). |
| `GET /v1/library?limit=&cursor=` | `{items, nextCursor}`, newest first. `limit` 1 to 200 (default 50). |
| `PUT /v1/files/{id}/keep` `{keep}` | `{ok, keep}`; `404` if unknown. |
| `DELETE /v1/files/{id}` | Removes the file and its sidecar. `200 {deleted: true}`, `404 {deleted: false}`, `409` while the job is running. |

Downloads made before metadata was recorded have an empty title and thumbnail. At every start the
server asks yt-dlp (no download) to describe each of them, one at a time, and fills the sidecar in
(keep, download time and size are untouched). A video yt-dlp cannot describe is retried at the next
start. Downloads and the data volume survive restarts and image updates; only a job in progress is lost.

Safety: ids must match `^[A-Za-z0-9_-]{11}$`; yt-dlp is started with an argument list (never a
shell); kept downloads never expire and unkept downloads are capped at `YTDLP_UNKEPT_CAP_GB`
(oldest evicted first); logs show method and path only, never tokens.

## Tests

```bash
cd tools/ytdlp-server && python3 -m unittest discover -s tests -v
```

The tests use a fake `yt-dlp` (`tests/fake_ytdlp.py`), so they need no network and no yt-dlp.
