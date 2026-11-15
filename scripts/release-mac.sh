#!/bin/zsh
# Wazy for Mac — Developer ID release build.
#
# Full pipeline: archive (Universal) -> export (Developer ID) -> notarize app
# -> staple -> zip -> DMG (with /Applications symlink) -> sign + notarize DMG
# -> staple -> spctl verify -> sha256.
#
# Usage:
#   scripts/release-mac.sh 1.1.28 [build]   # bumps Info.plist + project.yml, commits, then builds
#   scripts/release-mac.sh 1.1.28            # builds without bumping (already bumped)
#   V=1.1.28 scripts/release-mac.sh          # env override for the version
#
# Requires:
#   - Xcode (xcodebuild, xcrun notarytool/stapler)
#   - A stored notary keychain profile (default: "App Store Connect Profile";
#     override with NOTARY_PROFILE=...)
#   - Team 469UCUB275 signing identity / provisioning (override with TEAM=...)
#
# Output: $OUT (default /tmp/wazy-rel)
#   Wazy-<V>-macOS.dmg / .zip, plus arch.xcarchive, out/Wazy.app, logs.
# Publish afterwards with:
#   gh release create v<V> --title "Wazy <V> for Mac" --target "$(git rev-parse HEAD)" --latest \
#     --notes-file notes.md /tmp/wazy-rel/Wazy-<V>-macOS.dmg /tmp/wazy-rel/Wazy-<V>-macOS.zip

set -e
setopt null_glob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"            # repo root
PROJ="$ROOT/Wazy.xcodeproj"
INFO_PLIST="$ROOT/Sources/Info.plist"
PROJECT_YML="$ROOT/project.yml"

V="${1:-${V:-}}"
BUILD="${2:-}"
[ -n "$V" ] || { echo "usage: $0 <version> [build]   (or V=<version> $0)" >&2; exit 2; }

R="${OUT:-/tmp/wazy-rel}"
PROFILE="${NOTARY_PROFILE:-App Store Connect Profile}"
TEAM="${TEAM:-469UCUB275}"
SIGN_ID="${SIGN_ID:-Developer ID Application: Todd Bruss ($TEAM)}"

# --- optional version bump ---------------------------------------------------
if [ -n "$BUILD" ]; then
  plutil -replace CFBundleShortVersionString -string "$V" "$INFO_PLIST"
  plutil -replace CFBundleVersion -string "$BUILD" "$INFO_PLIST"
  sed -i '' -e "s/CFBundleShortVersionString: .*/CFBundleShortVersionString: \"$V\"/" -e "s/CFBundleVersion: .*/CFBundleVersion: \"$BUILD\"/" "$PROJECT_YML"
  if [ -n "$(git -C "$ROOT" status --porcelain -- "$INFO_PLIST" "$PROJECT_YML")" ]; then
    git -C "$ROOT" add "$INFO_PLIST" "$PROJECT_YML"
    git -C "$ROOT" commit -m "Version $V (build $BUILD)" >/dev/null
    echo "== bumped to $V (build $BUILD), committed $(git -C "$ROOT" rev-parse --short HEAD)"
  fi
fi

rm -rf $R/arch.xcarchive $R/out $R/dmg $R/notarize.zip \
       $R/Wazy-$V-macOS.zip $R/Wazy-$V-macOS.dmg
mkdir -p $R/out $R/dmg

cat > $R/export.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>signingStyle</key><string>automatic</string>
<key>teamID</key><string>$TEAM</string>
</dict></plist>
EOF

echo "== archive ($V)"
xcodebuild archive -project "$PROJ" -scheme Wazy -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath $R/arch.xcarchive ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  ENABLE_HARDENED_RUNTIME=YES DEVELOPMENT_TEAM=$TEAM -allowProvisioningUpdates | tail -3

echo "== export"
xcodebuild -exportArchive -archivePath $R/arch.xcarchive -exportPath $R/out \
  -exportOptionsPlist $R/export.plist -allowProvisioningUpdates | tail -3

APP=$R/out/Wazy.app
codesign -dv --verbose=2 "$APP" 2>&1 | grep -E "Authority=Developer|flags|TeamIdentifier"
lipo -archs "$APP/Contents/MacOS/Wazy"
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"

echo "== notarize app"
ditto -c -k --keepParent "$APP" $R/notarize.zip
xcrun notarytool submit $R/notarize.zip --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" $R/Wazy-$V-macOS.zip

echo "== dmg"
cp -R "$APP" $R/dmg/
ln -s /Applications $R/dmg/Applications
hdiutil create -volname "Wazy" -srcfolder $R/dmg -ov -format UDZO $R/Wazy-$V-macOS.dmg
codesign --sign "$SIGN_ID" --timestamp $R/Wazy-$V-macOS.dmg
xcrun notarytool submit $R/Wazy-$V-macOS.dmg --keychain-profile "$PROFILE" --wait
xcrun stapler staple $R/Wazy-$V-macOS.dmg

echo "== verify"
spctl -a -vv "$APP"
spctl -a -t open --context context:primary-signature -vv $R/Wazy-$V-macOS.dmg
shasum -a 256 $R/Wazy-$V-macOS.dmg $R/Wazy-$V-macOS.zip
echo "== DONE  dmg+zip in $R (Wazy-$V-macOS.*)"
