#!/usr/bin/env bash
# Switch paid-account-only entitlements OFF (or back ON) without removing them from the repo.
#
#   scripts/free-account.sh on       strip iCloud key-value sync from the app entitlements
#   scripts/free-account.sh off      restore the committed (full) entitlements via git
#   scripts/free-account.sh status   show which paid entitlements are currently present
#
# The committed files always keep the full set. "on" edits the working copies only, so
# `git checkout` / `off` brings them back. See docs/how-to/free-account-build.md.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
files=(
  "SmartTubeApp/SmartTubeApp/SmartTubeApp.entitlements"
  "SmartTubeApp/SmartTubeApp/SmartTubeApp-macOS.entitlements"
)
# Keys that need a paid Apple Developer Program membership.
paid_keys=("com.apple.developer.ubiquity-kvstore-identifier")

has_key() { /usr/libexec/PlistBuddy -c "Print :$2" "$root/$1" >/dev/null 2>&1; }

case "${1:-status}" in
  on)
    for f in "${files[@]}"; do
      for k in "${paid_keys[@]}"; do
        if has_key "$f" "$k"; then /usr/libexec/PlistBuddy -c "Delete :$k" "$root/$f"; fi
      done
    done
    echo "Paid entitlements switched OFF in the working tree (committed files unchanged)."
    ;;
  off)
    cd "$root" && git checkout -- "${files[@]}"
    echo "Full entitlements restored."
    ;;
  status)
    for f in "${files[@]}"; do
      for k in "${paid_keys[@]}"; do
        if has_key "$f" "$k"; then echo "ON   $k  ($f)"; else echo "OFF  $k  ($f)"; fi
      done
    done
    ;;
  *) echo "usage: $0 on|off|status" >&2; exit 2 ;;
esac
