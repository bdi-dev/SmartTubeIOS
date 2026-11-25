#!/usr/bin/env bash
# Build an UNSIGNED iOS .ipa that SideStore / AltStore can sign on the phone.
#
#   scripts/build-sidestore-ipa.sh [output-dir]      default output: build/sidestore/SmartTube.ipa
#
# SideStore re-signs with your Apple ID, so no signing happens here. The script itself switches the
# paid-only iCloud entitlement off and the bundle IDs to the personal prefix for the build, and
# restores the committed files when it exits (success or failure). See docs/how-to/sidestore-refresh.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# SideStore updates an installed app in place (keeping its data) only when the bundle ID is the same
# as before; a different ID installs as a NEW app, which on a free account hits the 3-app limit and
# starts with no data. The ID is therefore fixed: always <prefix>.app, never the committed com.void.
prefix="${SIDESTORE_BUNDLE_PREFIX:-com.bdi.smarttube}"
expected_id="$prefix.app"

# The helper scripts restore files with `git checkout`, which would discard uncommitted edits.
if ! git -C "$root" diff --quiet -- SmartTubeApp SmartTubeIOS/Sources; then
  echo "Uncommitted changes in SmartTubeApp/ or SmartTubeIOS/Sources/: commit or stash them first," >&2
  echo "because this script switches IDs and entitlements in the working tree and restores them." >&2
  exit 1
fi
restore() {
  "$root/scripts/personal-bundle-id.sh" off >/dev/null
  "$root/scripts/free-account.sh" off >/dev/null
}
trap restore EXIT
"$root/scripts/personal-bundle-id.sh" on "$prefix" >/dev/null
"$root/scripts/free-account.sh" on >/dev/null

out="${1:-$root/build/sidestore}"
dd="$out/DerivedData"
mkdir -p "$out"

cd "$root"
xcodebuild build \
  -workspace SmartTube.xcworkspace -scheme SmartTube \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath "$dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  | tail -n 5

app="$(find "$dd/Build/Products/Release-iphoneos" -maxdepth 1 -name '*.app' | head -n 1)"
[ -n "$app" ] || { echo "No .app produced" >&2; exit 1; }

actual_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
if [ "$actual_id" != "$expected_id" ]; then
  echo "Built bundle ID is $actual_id, expected $expected_id; refusing to export an IPA that would" >&2
  echo "install as a new app (and lose the old app's data) instead of updating in place." >&2
  exit 1
fi

rm -rf "$out/Payload" "$out/SmartTube.ipa"
mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
(cd "$out" && zip -qry SmartTube.ipa Payload && rm -rf Payload)
echo "Built: $out/SmartTube.ipa ($(du -h "$out/SmartTube.ipa" | cut -f1))"
