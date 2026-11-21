#!/usr/bin/env bash
# Build an UNSIGNED iOS .ipa that SideStore / AltStore can sign on the phone.
#
#   scripts/build-sidestore-ipa.sh [output-dir]      default output: build/sidestore/SmartTube.ipa
#
# SideStore re-signs with your Apple ID and rewrites the bundle ID, so no signing happens here.
# Run `scripts/free-account.sh on` first (paid-only iCloud entitlement off), and do not commit
# while it is on. See docs/how-to/sidestore-refresh.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

rm -rf "$out/Payload" "$out/SmartTube.ipa"
mkdir -p "$out/Payload"
cp -R "$app" "$out/Payload/"
(cd "$out" && zip -qry SmartTube.ipa Payload && rm -rf Payload)
echo "Built: $out/SmartTube.ipa ($(du -h "$out/SmartTube.ipa" | cut -f1))"
