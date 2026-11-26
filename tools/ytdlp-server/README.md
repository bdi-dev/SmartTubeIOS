# SmartTube yt-dlp companion server

A small, **dependency-free** (Python 3.9+ standard library) HTTP service that runs `yt-dlp` on your
always-on machine so the app can fetch videos its own extractor cannot. Design and rollout plan:
[docs/features/ytdlp-companion-server.md](../../docs/features/ytdlp-companion-server.md). Multiple
users: [docs/superpowers/plans/2026-11-25-nas-multi-user.md](../../docs/superpowers/plans/2026-11-25-nas-multi-user.md).

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

export YTDLP_TOKEN="$(openssl rand -hex 32)"   # becomes the admin token (see Users and tokens)
python3 tools/ytdlp-server/server.py            # listens on 127.0.0.1:8787
```

Reach it from your phone over Tailscale (`tailscale serve --bg 8787` gives HTTPS) or your LAN
(`YTDLP_HOST=0.0.0.0`). **Do not expose it to the public internet.**

Settings (environment): `YTDLP_TOKEN` (required at first start), `YTDLP_BIN`, `YTDLP_DATA_DIR`,
`YTDLP_HOST`, `YTDLP_PORT`, `YTDLP_MAX_CONCURRENT` (2), `YTDLP_UNKEPT_CAP_GB` (20; the default cap for
new users; kept downloads have no cap), `YTDLP_MAX_HEIGHT` (1080), `YTDLP_COOKIES` (optional
cookies.txt for age-restricted/members videos; stays on this machine), `YTDLP_PUBLIC_URL` (optional;
the address users reach the server at, used to print invite links on the command line).

## Users and tokens

Each person has a **profile** with a personal token. The server stores only a SHA-256 hash of each
token (`<data>/profiles.json`) and compares hashes in constant time. A request with no token or an
unknown token gets `401`.

- **Roles.** A profile is `admin` or `user`. Admins manage users; users see only their own list.
- **The admin profile.** `YTDLP_TOKEN` creates the `admin` profile the first time the server starts
  with it. After that the variable is not read again: change the admin token from the admin page
  (or `reissue-user`). Existing installs keep working with their current token, because that token
  is the admin's. On the first start with this version, every existing download is given to `admin`
  (with its keep flag). Nothing is moved or deleted. Back up the data volume before the first redeploy.
- **Lists are per user; files are shared.** Each video is stored once (`<id>.mp4`). Ownership lives in
  `<data>/owners/<profile>.json`. A profile sees only the videos it owns.
- **Dedup.** Asking for a video that is already on disk adds the caller as an owner and returns
  `ready`, with no yt-dlp run. Asking for a video that is downloading joins that download.
- **Keep is per profile.** A kept video is never evicted from its owner's list.
- **Delete removes your ownership.** The file is removed when its last owner leaves.
- **Cap is per profile.** The unkept cap (default 20 GB) counts every unkept video in your list,
  including videos others also own, in full. Over the cap, your own oldest unkept entries are removed
  from your list. The sum of everyone's totals can exceed what is on disk; that is intended.
- **Files need ownership.** `/v1/files/{id}.mp4` and `/v1/jobs/{id}` return `404` to anyone who does
  not own or has not requested the video. This does not protect against the server's owner or someone
  on the network; use HTTPS (Tailscale) for that.

Lost device: an admin revokes the token and issues a new one. The user's list is untouched.

### Command line (inside the container)

```bash
docker exec -it <container> python server.py add-user sam [--admin]   # prints the token once (and an invite link if YTDLP_PUBLIC_URL is set)
docker exec -it <container> python server.py revoke-user sam          # revokes the token; the list is kept
docker exec -it <container> python server.py reissue-user sam         # new token; the old one stops working
```

`USER` is a profile id or a name. Without Docker, run the same commands with `YTDLP_DATA_DIR` set.

### Admin page

`GET /admin` is one inline HTML+JS page served by the server. It holds no data: it calls
`/v1/admin/*` with `Authorization: Bearer <admin token>` from `fetch`. There are no cookies. The token is
kept in `sessionStorage` for the tab only, and is sent only to this server.

The page shows a users table: name, role, last seen, video count, unkept usage against the cap (with
an editable cap), and actions: promote or demote, new token, revoke token, delete. **Add user** shows
the token once, with an invite link `smarttube://nas?url=<server url>&token=<token>` and a copy button.
It shows counts and sizes only, never other users' titles. Deleting a user removes their ownership;
files nobody else owns are deleted. At least one admin always remains: the last admin cannot be
deleted or demoted.

## Try it with curl

```bash
B=http://127.0.0.1:8787; A="Authorization: Bearer $YTDLP_TOKEN"; ID=dQw4w9WgXcQ

curl -s $B/v1/health                                   # {"ok": true, "apiVersion": 4, "ytdlpVersion": "..."}
curl -s -H "$A" $B/v1/me                               # {"id": "admin", "name": "Admin", "role": "admin", "capBytes": 21474836480}
curl -s -X POST -H "$A" -d "{\"videoId\":\"$ID\",\"title\":\"A video\",\"keep\":true}" $B/v1/jobs   # 202 {"status":"queued",...}
curl -s -H "$A" $B/v1/jobs/$ID                         # poll: queued | running | ready | failed
curl -s -H "$A" -o out.mp4 $B/v1/files/$ID.mp4        # download (supports Range)
curl -s -H "$A" "$B/v1/library?limit=50"               # newest first; pass nextCursor back as &cursor=
curl -s -X PUT -H "$A" -d '{"keep":false}' $B/v1/files/$ID/keep   # unkeep: now subject to your cap
curl -s -X DELETE -H "$A" $B/v1/files/$ID              # remove it from your list (the file goes with its last owner)
curl -s -H "$A" $B/v1/admin/users                      # admin only: users with counts and sizes
```

## API

| Method & path | Notes |
|---|---|
| `GET /v1/health` | No auth. `{ok, apiVersion, ytdlpVersion}`; `apiVersion` 4 adds profiles, ownership and the admin API. |
| `GET /v1/me` | `{id, name, role, capBytes}` for the caller. |
| `POST /v1/jobs` `{videoId, maxHeight?, title?, channelTitle?, duration?, thumbnailURL?, keep?}` | Idempotent per caller. Dedup and joining as described above. `keep` defaults to `true`. `202` with the job state. |
| `GET /v1/jobs/{id}` | `{status, progress, error?, fileSize?}`; `404` unless you own the video or requested it. |
| `GET /v1/files/{id}.mp4` | The file; `Range` supported (`206`/`416`). `404` unless you own the video. |
| `GET /v1/library?limit=&cursor=` | `{items, nextCursor}`, newest first, your list only. `limit` 1 to 200 (default 50). |
| `PUT /v1/files/{id}/keep` `{keep}` | Your keep flag. `{ok, keep}`; `404` unless you own the video. |
| `DELETE /v1/files/{id}` | Removes your ownership. `200 {deleted: true}`, `404 {deleted: false}`, `409` while still downloading. |
| `GET /admin` | The admin page. No auth; it holds no data. |
| `GET /v1/admin/users` | Admin only. `{users: [{id, name, role, createdAt, lastSeen, capBytes, hasToken, videoCount, totalBytes, unkeptBytes}]}`. |
| `POST /v1/admin/users` `{name, role?}` | Admin only. `201 {user, token}`; the token is shown once. `role` defaults to `user`. |
| `PATCH /v1/admin/users/{id}` `{name?, role?, capBytes?}` | Admin only. `200 {user}`. `409` if it would leave no admin. |
| `POST /v1/admin/users/{id}/token` | Admin only. New token, `200 {user, token}`; the old token stops working. |
| `DELETE /v1/admin/users/{id}/token` | Admin only. Revokes the token, `200 {user}`; the list is kept. |
| `DELETE /v1/admin/users/{id}` | Admin only. Removes the profile and its ownership, `200 {deleted: true}`. `409` for the last admin. |

Errors are `{"error": "..."}`: `401 {"error": "unauthorised"}` for a missing or unknown token,
`403 {"error": "forbidden"}` for a user calling an admin route, `400` for bad input (the message names
the field, e.g. `{"error": "bad keep"}`).

Downloads made before metadata was recorded have an empty title and thumbnail. At every start the
server asks yt-dlp (no download) to describe each of them, one at a time, and fills the sidecar in
(keep, download time and size are untouched). A video yt-dlp cannot describe is retried at the next
start. Downloads, profiles and the data volume survive restarts and image updates; only a job in
progress is lost.

Safety: ids must match `^[A-Za-z0-9_-]{11}$`; yt-dlp is started with an argument list (never a
shell); tokens are stored only as hashes and never logged; logs show method and path only; files are
written atomically under a lock.

## Tests

```bash
cd tools/ytdlp-server && python3 -m unittest discover -s tests -v
```

The tests use a fake `yt-dlp` (`tests/fake_ytdlp.py`), so they need no network and no yt-dlp. It can
log each run (`FAKE_YTDLP_LOG`) so tests can count downloads, and sleeps for ids containing `SLOW`.

Caps are admin-only: users can see their own cap in `GET /v1/me` but only an admin can change it (`/admin` page or `PATCH /v1/admin/users/<id>`).
