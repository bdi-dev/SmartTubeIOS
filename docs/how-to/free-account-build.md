# Building with a free Apple ID

A free personal team cannot sign apps that carry paid-only capabilities. SmartTube keeps those
capabilities **switchable, not removed**: the committed entitlements always contain the full set,
and a script turns the paid ones off in your working tree.

## Paid-only capabilities in this app

| Capability | Where | Effect when switched off |
|---|---|---|
| iCloud key-value sync (`com.apple.developer.ubiquity-kvstore-identifier`) | iOS and macOS app entitlements | "Sync to iCloud" is disabled in Settings with an explanation; everything else works locally. |

Not paid-only: Live Activities (an Info.plist key, no entitlement), background audio, local
notifications, background app refresh. New features are designed to stay in this group (for
example new-upload alerts use *local* notifications, never push).

Watch item: the app uses an App Group (`group.com.void.smarttube`) to share data with the Share
extension and the Download widget. Apple's capability table for personal teams should allow it,
but this has not been verified on a free account here. If signing fails on the group, the Share
extension and widget lose shared data; the main app is unaffected.

## Switching

```bash
just free-account on      # strip paid entitlements from the working tree
just free-account status  # show what is currently on/off
just free-account off     # restore the committed (full) entitlements
```

`on` edits only the working copies of the two app entitlements files; `off` runs `git checkout`
on them. Do not commit while `on` is active.

## When the bundle IDs belong to another team

Bundle IDs and App Groups are unique across all Apple teams. If `com.void.smarttube.*` is
registered to a different team, a free personal team cannot sign the app. Swap to your own prefix in
the working tree:

```bash
scripts/personal-bundle-id.sh on com.yourname.smarttube   # rewrite IDs, App Group, background task id
scripts/personal-bundle-id.sh status
scripts/personal-bundle-id.sh off                          # git checkout the touched files
```

Like `free-account.sh`, this edits working copies only; do not commit while it is on. A free team
also allows 10 new App IDs per week and 3 apps per device.
