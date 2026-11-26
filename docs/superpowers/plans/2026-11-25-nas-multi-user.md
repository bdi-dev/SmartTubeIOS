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
3. **Keep is per profile.** A kept entry is never evicted from its owner's list.
4. **Delete from NAS removes the caller's ownership only.** The file is deleted from disk when the
   last owner is gone. Other profiles' lists are unaffected.
5. **The unkept cap is per profile** (default 20 GB, editable per profile from the app, see
   [NAS status](2026-11-25-nas-status-usage.md)). A profile's total is the size of every unkept
   video in its list, **including videos other profiles also own**: a shared file counts in full
   toward each owner. The sum of all totals can therefore exceed what is on disk, and the disk may
   never fill to the sum of the caps. That is intended.
   When a profile goes over its cap, the server evicts **that profile's** oldest unkept entries
   (removes its ownership). The file leaves the disk only when its last owner is gone.
6. **One shared token.** The profile travels in `X-SmartTube-Profile: <id>`; absent means
   `default`, so existing installs keep working unchanged. Ids match `[a-z0-9_-]{1,32}` and are
   auto-created on first use when `YTDLP_AUTO_CREATE_PROFILES` is on (default on).

## Profiles: creation and handling
- **Identity** is a profile id plus a display name. The id is a slug of the name the user typed
  ("Sam" becomes `sam`); the app sends it in the header and stores it in `AppSettings`.
- **Creation:** on first launch after updating, Settings > NAS asks "Who is using this device?".
  The field offers the server's existing profiles (`GET /v1/profiles`) to pick, plus "New profile"
  to type a name. A new id is created on its first request (`YTDLP_AUTO_CREATE_PROFILES`, default
  on; when off, the server rejects unknown ids and profiles are added by editing
  `<data>/profiles.json`). Until a profile is chosen the device acts as `default`, so existing
  installs keep working and keep their current downloads.
- **Rename:** `PUT /v1/profile` changes the display name; the id never changes.
- **Delete:** `DELETE /v1/profile` removes the caller's whole list (ownership only; files with no
  remaining owner are deleted). The app asks for confirmation. No automatic cleanup of idle profiles.
- **Switching profile** on a device reloads the NAS list. Nothing is merged or moved between
  profiles. A typo creates a stray empty profile, which is why picking an existing one comes first.

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
5. Eviction runs per profile over its own unkept entries, oldest first; a file is removed from
   disk only when no owner remains.
6. `GET /v1/profiles`, `PUT /v1/profile` (display name) and `DELETE /v1/profile`. Bump `API_VERSION` to 4; older apps
   keep working as `default`.
7. Tests: B requesting A's video starts no yt-dlp run and appears only in B's list; lists are
   disjoint otherwise; keep is the OR of owners for eviction; deleting with another owner keeps the
   file, deleting as the last owner removes it; a shared file counts in full toward each owner's total and evicting one owner leaves the file for the other; a concurrent
   request for an in-flight id joins it; migration is idempotent; bad ids are rejected.
8. README: say this is separation, not access control. Redeploy stack 42.

## App work
1. `AppSettings` gains a profile id and display name. Settings > NAS has the profile picker and
   "New profile" flow described above, plus the not-secure note.
2. `YtDlpLibraryClient` and the fetcher send the profile header when set.
3. Changing the profile reloads the NAS list (the `serverIdentity` task hash gains the profile id).
4. A server too old for profiles hides the field. No other view-model changes, since the list is
   already scoped server side.
5. Tests with fake clients: header sent only when set, list reloads on profile change, old-server
   fallback.

## Non-goals
- No passwords, per-user tokens or encryption (real security is a different plan).
- No sharing toggles or "private" flag: visibility is simply per user. No admin screen.

## Open questions
- Show another profile's existing copy as "Available instantly" in search results before
  requesting? (Not now.)
