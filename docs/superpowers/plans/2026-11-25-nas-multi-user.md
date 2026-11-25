# NAS multiple users — feature plan

> Status: proposed, not started. Personal-use build only (sideloaded, never submitted).
> Follows [NAS library](2026-11-23-nas-library.md). Do one task at a time, verify, then commit.

## Goal
Let more than one person share the same NAS server while each sees a personalised "Available on
NAS" list. This is **separation, not security**: it keeps people's lists tidy and keeps one
person's pins and deletes from affecting another's view. Anyone with the server address can
still reach any file. The README and the settings screen say so plainly.

## Model
- Each person has a **profile**: a short id (`[a-z0-9_-]{1,32}`) and a display name. Profiles live
  in `profiles.json` in the data volume; the first request from an unknown profile id is rejected
  unless auto-create is on (`YTDLP_AUTO_CREATE_PROFILES`, default on for a home network).
- Video files stay **shared and deduplicated**: one copy of `<id>.mp4` on disk, however many
  people want it. A download request from any profile reuses the existing file.
- Per-profile state is a small **ownership record**: which profiles have the video in their list,
  and each profile's `keep` flag for it. The existing sidecar keeps the shared facts (title,
  channel, duration, size, downloadedAt).
- **Private** means "only in my list". A private video is hidden from other profiles' lists. It is
  still a shared file, and anyone who knows the video id can fetch `/v1/files/<id>.mp4`.
- The shared token stays. The profile is sent as a header `X-SmartTube-Profile: <id>`; absent
  means the `default` profile, so existing installs keep working with no change.

## Behaviour
- **Available list** shows videos owned by the caller, plus videos marked shared (the default for
  new downloads is configurable per profile: "Share my downloads" on or off).
- **Keep** is per profile. A file is unkept (eligible for the 20 GB cap eviction) only when **no**
  profile keeps it. Eviction removes the file and every ownership record.
- **Delete from NAS** removes the caller's ownership. The file is deleted only when no owners
  remain; otherwise the caller just stops seeing it. A "Delete for everyone" action is out of
  scope.
- Migration: existing sidecars become owned by `default` with their current `keep`, shared on.

## Server work (`tools/ytdlp-server/server.py`)
1. Profile resolution from the header, validated against the id pattern; `profiles.json` with
   atomic writes under the existing lock.
2. Ownership records alongside sidecars (`<id>.owners.json`) and a one-time migration at startup.
3. `GET /v1/library` filters by caller; `PUT /v1/files/<id>/keep` and `DELETE` act per profile as
   above; `POST` submits add the caller as an owner even when the file already exists.
4. `GET /v1/profiles` (list, for the picker) and `PUT /v1/profile` (rename, share default).
5. Bump `API_VERSION` to 4; older apps keep working as `default`.
6. Tests: two profiles see different lists; shared file counted once; keep is the OR of owners;
   deleting with other owners keeps the file; eviction clears owners; migration; bad ids.
7. README: state clearly that this is not an access control. Redeploy stack 42.

## App work
1. Settings > NAS: profile name field (stored in `AppSettings`), "Share my downloads" toggle, and
   a note that this separates lists but is not private.
2. Send the profile header from `YtDlpLibraryClient` and the fetcher, when set.
3. `NASLibraryViewModel` is unchanged apart from the client; the list is just filtered server
   side. Show a small "shared" badge on rows owned by someone else and a "Private" toggle in the
   row long-press menu.
4. Handle `serverTooOld` (no profile support) by hiding the profile controls.
5. Tests with fake clients: header sent, badge and toggle states, old-server fallback.

## Non-goals
- No passwords, per-user tokens, or encryption (that would be real security and a different
  plan). No per-user quotas or admin screen.

## Open questions
- Should "Private" be the default for new profiles? (Proposed: shared, since this is a family box.)
- Fold the per-user usage breakdown into [NAS status](2026-11-25-nas-status-usage.md)?
