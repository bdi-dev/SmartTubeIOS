# NAS multiple users — feature plan

> Status: proposed, not started. Personal-use build only (sideloaded, never submitted).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.

## Goal
Let more than one person use the same NAS server, each with their **own** downloads. This is
**separation, not security**: it keeps people's lists apart and personal. Anyone with the shared
token can still send another profile's id and see its list. The README and the Settings screen say
so plainly.

## Decisions
1. **No shared files.** Every download belongs to exactly one profile. If two people download the
   same video, the NAS holds two copies. There is no deduplication across profiles and no
   "shared" or "private" toggle: everything is the owner's.
2. **Per-profile storage.** Each profile has its own folder: `<data>/profiles/<id>/` holding the
   `.mp4` files and sidecars exactly as today. The existing layout becomes the `default` profile.
3. **Everything is per profile**: the library list, keep flags, delete, job status, and the
   unkept cap. The unkept cap (default 20 GB) applies **per profile**, is **editable per
   profile** from the app ([NAS status](2026-11-25-nas-status-usage.md)), and eviction only touches
   that profile's own unkept files. The cap is stored per profile in its `settings.json`.
4. **One shared token.** The profile travels in a header, `X-SmartTube-Profile: <id>`. No header
   means `default`, so existing installs keep working unchanged.
5. **Profile ids** match `[a-z0-9_-]{1,32}`. An unknown id is created on first use when
   `YTDLP_AUTO_CREATE_PROFILES` is on (default on for a home network); otherwise it is rejected.

## Behaviour
- **Available on NAS** lists only the caller's files. Other profiles' files never appear.
- **Download request** by a profile fetches a fresh copy into that profile's folder, even if
  another profile already holds the video.
- **Keep, unkeep, delete from NAS** affect only the caller's copy.
- **File serving** (`/v1/files/<id>.mp4`) resolves inside the caller's folder only; a request for a
  video the caller does not own returns 404.
- **Storage cost** is the sum of every profile's copies. The status screen
  ([NAS status](2026-11-25-nas-status-usage.md)) should show usage per profile.

## Server work (`tools/ytdlp-server/server.py`)
1. Resolve the profile once per request from the header and validate it; map it to its folder and
   give each profile its own lock and eviction state, so profiles cannot block each other.
2. One-time migration at startup: if files exist in the old flat layout, move them into
   `profiles/default/`. It is idempotent and logs counts only.
3. Route every existing endpoint through the profile's folder. Add `GET /v1/profiles` (ids and
   display names, for a picker) and `PUT /v1/profile` (set a display name).
4. Bump `API_VERSION` to 4. Older apps keep working as `default`.
5. Tests: two profiles download the same id and get separate files; lists are disjoint; keep and
   delete do not cross over; eviction is per profile; the file route 404s across profiles; bad
   ids are rejected; migration moves old files and is safe to re-run.
6. README: state clearly this is separation, not access control. Redeploy stack 42, and take a
   volume backup first because of the migration.

## App work
1. `AppSettings` gains a profile id and display name. Settings > NAS shows a "Who is using this
   device" field and the not-secure note.
2. `YtDlpLibraryClient` and the fetcher send the profile header when set.
3. No view-model changes: the list is already scoped server side. Changing the profile reloads the
   NAS list (the existing `serverIdentity` task hash gains the profile id).
4. Handle an old server (no profile support) by hiding the profile field.
5. Tests with fake clients: header sent only when set, list reloads on profile change, old-server
   fallback.

## Non-goals
- No passwords, per-user tokens or encryption (that is real security and a different plan).
- No sharing, copying or transferring a download between profiles, no admin screen, no quotas
  beyond the per-profile unkept cap.

## Open questions
- Should a "Copy from another profile" action exist later? (Not now; decision 1 says no sharing.)
