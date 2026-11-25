# Keeping a free-account install alive with SideStore

A free Apple ID signs apps for 7 days. [SideStore](https://github.com/SideStore/SideStore) re-signs
them **on the phone**, so you do not need the Mac (or to be home) after a one-time setup. This is a
stopgap until the paid developer account is approved (1-year profiles, TestFlight).

## Risk, plainly

- SideStore talks to Apple's developer services with your Apple ID through third-party tooling.
  No source found reports Apple locking an account for this, but it is a grey area. **Use a separate
  Apple ID created for this**, not your main one, and only install SideStore from its official site.
- Documented failure modes: revoked certificates, the App ID cap (about 10 per week), 3 devices
  per week, and anisette errors that clear on retry. None is permanent.
- Unverified here: everything below about on-device behaviour. Treat the first week as a trial.

## One-time setup (needs the Mac, on the same Wi-Fi as the phone)

1. Follow the official SideStore install guide to put SideStore on the phone and create the pairing
   file. Sign in with the **secondary** Apple ID. Enable Developer Mode on the phone.
2. Install the on-device VPN/loopback helper the guide names (SideStore needs it to refresh without
   a computer). Leave it enabled.
3. In SideStore, turn on background refresh, and keep Background App Refresh on for SideStore.

## Building the app for SideStore

```bash
scripts/free-account.sh on          # strip the paid-only iCloud entitlement (working copy only)
scripts/build-sidestore-ipa.sh      # -> build/sidestore/SmartTube.ipa (unsigned)
scripts/free-account.sh off         # restore entitlements before committing
```

AirDrop or copy the `.ipa` to the phone, then in SideStore: **My Apps → +** and choose the file.
SideStore signs it with the secondary ID, rewriting the bundle ID.

## Updating in place (keeping your data)

Installing a newer IPA over the installed app keeps its data **only if the bundle ID is unchanged**.
The build is pinned to `com.void.smarttube.app`; `build-sidestore-ipa.sh` fails if it would produce
any other ID (for example when `scripts/personal-bundle-id.sh on` is left enabled). A different ID
installs as a second app, which uses one of the free account's three app slots and starts empty.

- Do not delete the installed app before updating; choose the new `.ipa` under **My Apps → +**.
- Never switch the ID after you have data you want to keep. If you must (set `SIDESTORE_BUNDLE_ID`),
  expect a fresh install and delete the old app afterwards.

## Things that behave differently

- **App Groups.** SideStore rewrites the bundle and App Group IDs, but the app's group constants are
  fixed strings. The main app is unaffected; sharing from the Share extension and the widget's
  shared data may not work until the constants read the rewritten group.
- **Extensions.** Each extension (Share, Safari, widget) is another App ID against the weekly cap.
  If you hit it, build without the extensions.
- **Fresh install.** A different signing identity means a different bundle ID, so it does not
  upgrade the Xcode-installed copy and starts with no data. Delete the old one after moving over.
- **Refresh timing.** Refresh happens in the background, roughly daily, when SideStore gets time.
  Open it manually before you travel; if it says "expiring in under 2 days", refresh now.

## When the paid account arrives

Rebuild with the committed (full) entitlements and distribute with TestFlight (builds last 90 days,
updates over the air) instead.
