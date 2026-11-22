#!/usr/bin/env bash
# Switch the app's bundle IDs / App Group to your own prefix so a free personal team can sign it
# (the com.void.smarttube.* IDs are registered to another team). Working copy only; `off` restores
# the committed files. Do not commit while it is on.
#   scripts/personal-bundle-id.sh on <prefix>   e.g. on com.bdi.smarttube
#   scripts/personal-bundle-id.sh off
#   scripts/personal-bundle-id.sh status
set -euo pipefail
cd "$(dirname "$0")/.."
OLD="com.void.smarttube"
FILES=(
  SmartTubeApp/SmartTubeApp.xcodeproj/project.pbxproj
  SmartTubeApp/SmartTubeApp/SmartTubeApp.entitlements
  SmartTubeApp/SmartTubeApp/SmartTubeApp-macOS.entitlements
  SmartTubeApp/ShareExtension/SmartTubeShareExtension.entitlements
  SmartTubeApp/DownloadWidget/SmartTubeDownloadWidget.entitlements
  SmartTubeApp/SmartTubeApp/Info.plist
  SmartTubeApp/Sources/AppEntry.swift
  SmartTubeApp/ShareExtension/ShareViewController.swift
  SmartTubeIOS/Sources/SmartTubeIOSCore/HomeWidgetSnapshot.swift
  SmartTubeIOS/Sources/SmartTubeIOS/Services/NewUploadNotifier.swift
)
case "${1:-status}" in
  on)
    NEW="${2:?usage: on <prefix>, e.g. com.bdi.smarttube}"
    sed -i '' -E "/PRODUCT_BUNDLE_IDENTIFIER/ s/${OLD//./\\.}/${NEW}/" "${FILES[0]}"
    for f in "${FILES[@]:1:4}"; do sed -i '' "s/group\.${OLD//./\\.}/group.${NEW}/g" "$f"; done
    sed -i '' "s/${OLD//./\\.}\.app\.refresh/${NEW}.app.refresh/" SmartTubeApp/SmartTubeApp/Info.plist \
      SmartTubeIOS/Sources/SmartTubeIOS/Services/NewUploadNotifier.swift
    for f in SmartTubeApp/Sources/AppEntry.swift SmartTubeApp/ShareExtension/ShareViewController.swift \
      SmartTubeIOS/Sources/SmartTubeIOSCore/HomeWidgetSnapshot.swift; do
      sed -i '' "s/\"group\.${OLD//./\\.}\"/\"group.${NEW}\"/" "$f"
    done
    echo "Bundle IDs and App Group now use ${NEW} (working tree only)."
    ;;
  off)
    git checkout -- "${FILES[@]}"
    echo "Restored the committed bundle IDs (this also restores the iCloud entitlement: re-run free-account.sh on if needed)."
    ;;
  status)
    grep -h "PRODUCT_BUNDLE_IDENTIFIER" "${FILES[0]}" | sort -u | sed 's/^[[:space:]]*//'
    ;;
esac
