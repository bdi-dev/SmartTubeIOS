# NAS multiple users — feature plan

> Status: proposed, not started. Personal-use build only (sideloaded, never submitted).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.

## Goal
Let more than one person use the same NAS server. Each person's **"Available on NAS" list is
their own**, but the server **stores each video once**: if another user already downloaded it, a
new request is satisfied from the existing file and nothing is fetched again. This is
**separation, not security**: anyone with the shared token can claim any profile id, and anyone
who knows a video id can fetch its file. The README and the Settings screen say so plainly.

## Decisions
1. **Lists are per user; files are shared.** One `<id>.mp4` per video on disk. Each profile has an
   **ownership record** for the videos in its list. A profile never sees other profiles' entries.
2. **Dedup on request.** When profile B asks for a video that profile A already downloaded, the
   server adds B as an owner and returns it as finished immediately, with no yt-dlp run. B's list
   then shows it like any other download. (An in-flight job for the same id is joined, not
   duplicated.)
3. **Keep is per profile.** A file is eligible for cap eviction only when **no** owner keeps it.
4. **Delete from NAS removes the caller's ownership only.** The file is deleted from disk when the
   last owner is gone. Other profiles' lists are unaffected.
5. **The unkept cap stays one server-wide value** (default 20 GB, editable from the app, see
   [NAS status](2026-11-25-nas-status-usage.md)), counted over physical files with no keeping
   owner, so a shared file is counted once. Eviction removes the file and every ownership record
   for it. No per-profile quotas.
6. **One shared token.** The profile travels in `X-SmartTube-Profile: <id>`; absent means
   `default`, so existing installs keep working unchanged. Ids match `[a-z0-9_-]{1,32}` and are
   auto-created on first use when `YTDLP_AUTO_CREATE_PROFILES` is on (default on).

## Layout and migration
- Shared data stays where it is: `<data>/<id>.mp4` and its sidecar (title, channel, duration, size,
  downloadedAt). Ownership lives in `<data>/owners/<profile>.json` (`videoId -> {keep, addedAt}`),
  written atomically under the existing lock.
- Startup migration is idempotent: every existing sidecar becomes owned by `default` with its
  current `keep`. Nothing is moved or deleted. Back up the volume before the first redeploy anyway.

## Server work (`tools/ytdlp-server/server.py`)
1. Resolve and validate the profile once per request; load that profile's ownership map.
2. `POST /v1/jobs` (submit): if the file exists, add ownership and report done; if a job is
   running, add the caller as a pending owner and join it; else start the job with the caller as
   owner.
3. `GET /v1/library` lists the caller's owned videos only, joined with the shared sidecar data,
   with the existing keyset cursor. `PUT .../keep` and `DELETE` act on the caller's ownership as
   in decisions 3 and 4.
4. `GET /v1/files/<id>.mp4` serves the shared file for any valid profile (not secure by design,
   see Goal). The job status route reports the caller's view.
5. Eviction considers a file unkept only if no owner keeps it; removing it clears all owners.
6. `GET /v1/profiles` and `PUT /v1/profile` (display name). Bump `API_VERSION` to 4; older apps
   keep working as `default`.
7. Tests: B requesting A's video starts no yt-dlp run and appears only in B's list; lists are
   disjoint otherwise; keep is the OR of owners for eviction; deleting with another owner keeps the
   file, deleting as the last owner removes it; the cap counts a shared file once; a concurrent
   request for an in-flight id joins it; migration is idempotent; bad ids are rejected.
8. README: say this is separation, not access control. Redeploy stack 42.

## App work
1. `AppSettings` gains a profile id and display name. Settings > NAS has a "Who is using this
   device" field and the not-secure note.
2. `YtDlpLibraryClient` and the fetcher send the profile header when set.
3. Changing the profile reloads the NAS list (the `serverIdentity` task hash gains the profile id).
4. A server too old for profiles hides the field. No other view-model changes, since the list is
   already scoped server side.
5. Tests with fake clients: header sent only when set, list reloads on profile change, old-server
   fallback.

## Non-goals
- No passwords, per-user tokens or encryption (real security is a different plan).
- No sharing toggles or "private" flag: visibility is simply per user. No quotas, no admin screen.

## Open questions
- Show another profile's existing copy as "Available instantly" in search results before
  requesting? (Not now.)
