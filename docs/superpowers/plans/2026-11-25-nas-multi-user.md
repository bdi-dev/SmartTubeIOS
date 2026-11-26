# NAS multiple users — feature plan

> Status: proposed, not started. Personal-use build only (sideloaded, never submitted).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.
> Transport security is its own plan: [NAS HTTPS over Tailscale](2026-11-25-nas-https-tailscale.md).

## Goal
Let more than one person use the same NAS server. Each person authenticates with a **personal
token**, has their **own "Available on NAS" list and cap**, and the server **stores each video
once**: if another user already downloaded it, a new request is satisfied from the existing file
and nothing is fetched again. An **admin** manages users from a **web page** served by the server.

## Decisions
1. **Personal tokens are the identity.** Each profile has its own random token; the token
   identifies the caller, so there is no profile header and no auto-create. The server stores only
   a hash (SHA-256) of each token and compares with `hmac.compare_digest`.
2. **Roles.** A profile is `admin` or `user`. The existing `YTDLP_TOKEN` becomes the first admin's
   token at startup (profile id `admin`), so existing installs and devices keep working. Existing
   downloads are owned by `admin` after migration.
3. **Lists are per user; files are shared.** One `<id>.mp4` per video on disk. Each profile has an
   ownership record for the videos in its list and never sees other profiles' entries.
4. **Dedup on request.** If profile B asks for a video profile A already downloaded, the server
   adds B as an owner and reports it finished, with no yt-dlp run. A request for an in-flight id
   joins that job instead of starting a second one.
5. **Keep is per profile.** A kept entry is never evicted from its owner's list.
6. **Delete from NAS removes the caller's ownership only.** The file leaves the disk when its last
   owner is gone.
7. **The unkept cap is per profile** (default 20 GB). A profile's total is every unkept video in
   its list, **including videos other profiles also own**: a shared file counts in full toward
   each owner, so the sum of totals can exceed what is on disk. That is intended. Over its cap, a
   profile has its **own** oldest unkept entries evicted (ownership removed). A user edits their
   own cap in the app; an admin can edit anyone's on the web page.
8. **File access checks ownership.** `/v1/files/<id>.mp4` serves a video only to a profile that
   owns it, so a guessed id does not expose another user's file. Not protected against the server
   owner or an attacker on the network; HTTPS (separate plan) covers sniffing.

## Setup flow
1. Admin opens `https://<nas>/admin` (see Web admin page), pastes the admin token, taps **Add
   user**, types a name. The server creates the profile and shows a **one-time token** and an
   invite link `smarttube://nas?url=<server url>&token=<token>` with a copy button.
2. The user opens the link on their device (or pastes URL and token into Settings > NAS). The app
   calls `GET /v1/me`, which returns `{id, name, role}`, and shows "Signed in as Sam".
3. Lost device: admin taps **Revoke token** and then **New token**; the user's list is untouched.
4. Command-line fallback in the container: `python server.py add-user sam [--admin]`, `revoke-user
   sam`. It prints the token once.

## Web admin page
- Served by the server itself at `GET /admin` as one inline HTML+JS file (no dependencies, no
  build step). The page holds no data; everything comes from `/v1/admin/*` with
  `Authorization: Bearer <admin token>` in `fetch`, so there are no cookies and no CSRF surface.
  The token is kept in `sessionStorage` for the tab only.
- Shows a users table: name, role, last seen, video count, unkept usage against cap (a gauge),
  editable cap. Actions: add user, revoke or reissue token, promote or demote, delete user.
- Shows counts and sizes, **not** other users' titles.
- Also shows the NAS status block from [NAS status](2026-11-25-nas-status-usage.md) (disk, jobs,
  recent failures), so the admin has one place to look.
- Delete user asks for confirmation and removes that user's ownership; files with no remaining
  owner are deleted. At least one admin must always remain.

## Server work (`tools/ytdlp-server/server.py`)
1. `profiles.json` in the data volume: `{id, name, role, tokenHash, createdAt, lastSeen, capBytes}`
   with atomic writes under the existing lock. Auth resolves the bearer token to a profile; no
   match is a 401. The `/v1/health` route stays unauthenticated.
2. Startup migration (idempotent): create the `admin` profile from `YTDLP_TOKEN`; every existing
   sidecar becomes owned by `admin` with its current `keep`; nothing is moved or deleted.
   Ownership lives in `<data>/owners/<profile>.json` (`videoId -> {keep, addedAt}`). Back up the
   volume before the first redeploy.
3. Submit, library, keep, delete and file routes use the caller's ownership as in decisions 3 to 8.
   `GET /v1/me`.
4. `/v1/admin/*` (admin only): list, create, patch (name, role, cap), reissue token, delete.
5. `GET /admin` page, and the `add-user` and `revoke-user` CLI commands.
6. Bump `API_VERSION` to 4. An old app keeps working because the old token is the admin token.
7. Tests: a request with no or a wrong token gets 401; user B requesting A's video starts no
   yt-dlp run and appears only in B's list; lists are disjoint otherwise; a non-owner gets 404 on
   the file route; deleting with another owner keeps the file and the last owner removes it; a
   cap evicts only that profile's entries and a shared file counts in full toward each owner; a
   user cannot call `/v1/admin/*`; the last admin cannot be deleted or demoted; revoked tokens
   stop working at once; migration is idempotent; a concurrent request for an in-flight id joins it.
8. README: document tokens, roles, the admin page, and the limits above. Redeploy stack 42.

## App work
1. Settings > NAS: token field (Keychain, not `UserDefaults`), invite-link handler for the
   `smarttube://nas` URL, "Signed in as" row from `GET /v1/me`, own cap editor, sign-out. An
   invalid token shows a clear "token revoked or wrong" message instead of an empty list.
2. `YtDlpLibraryClient` and the fetcher send the personal token (the setting that exists today).
3. Changing the token reloads the NAS list (the `serverIdentity` hash already includes the token).
4. No admin UI in the app. A server too old for `/v1/me` simply hides the "Signed in as" row.
5. Tests with fake clients: 401 handling, invite link parsing, token stored in Keychain.

## Non-goals
- No in-app admin screen, no sharing toggles or "private" flag (visibility is per user), no
  passwords, no OAuth, no per-user rate limits.

## Open questions
- QR code for the invite link on the admin page? (Needs a small inline generator; skip at first,
  the link and copy button are enough.)
