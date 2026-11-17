#!/bin/zsh
# Wazy for iPhone and iPad — archive and upload to App Store Connect for TestFlight.
#
# Usage:
#   scripts/release-ios.sh 1.1.0 8   # bumps iOS/Info.plist to 1.1.0 (8), commits, archives, uploads
#   scripts/release-ios.sh           # archives and uploads the version already in iOS/Info.plist
#
# Requires Xcode signed in to team 469UCUB275 (automatic signing) and the app record
# com.starplayrx.wazy.ios in App Store Connect. Output: $OUT (default /tmp/wazy-ios).

set -e
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT/iOS/Info.plist"
R="${OUT:-/tmp/wazy-ios}"
TEAM="${TEAM:-469UCUB275}"

if [ -n "$2" ]; then
  plutil -replace CFBundleShortVersionString -string "$1" "$INFO_PLIST"
  plutil -replace CFBundleVersion -string "$2" "$INFO_PLIST"
  if [ -n "$(git -C "$ROOT" status --porcelain -- "$INFO_PLIST")" ]; then
    git -C "$ROOT" add "$INFO_PLIST"
    git -C "$ROOT" commit -m "iOS version $1 (build $2)" >/dev/null
  fi
fi
echo "== Wazy iOS $(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST") ($(plutil -extract CFBundleVersion raw "$INFO_PLIST"))"

rm -rf $R/arch.xcarchive $R/out
mkdir -p $R/out
cat > $R/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>upload</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
<key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
EOF

echo "== archive"
xcodebuild archive -project "$ROOT/Wazy.xcodeproj" -scheme Wazy -configuration Release \
  -destination "generic/platform=iOS" -archivePath $R/arch.xcarchive \
  DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates | tail -3

echo "== upload"
xcodebuild -exportArchive -archivePath $R/arch.xcarchive -exportPath $R/out \
  -exportOptionsPlist $R/export.plist -allowProvisioningUpdates | tail -5
echo "== DONE: the build appears in App Store Connect > TestFlight after processing (about 5-30 minutes)"
