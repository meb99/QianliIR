#!/bin/bash
# Builds "QianLi IR.app" (Apple Silicon + Intel) and a DMG in ./dist. Needs macOS with Xcode command line tools.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP="dist/QianLi IR.app"

swift build -c release --arch arm64 --arch x86_64 --product QianliIR
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

rm -rf dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/QianliIR" "$APP/Contents/MacOS/QianliIR"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"

# App icon from the 1024px PNG.
ICONSET="dist/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# Ad-hoc signature (no Apple developer account): enough for the camera permission prompt.
codesign --force --deep --sign - "$APP"
codesign --verify --verbose "$APP"

# Disk image with a shortcut to /Applications.
STAGE="dist/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Programme"
cp "docs/Installation.txt" "$STAGE/Installation – bitte lesen.txt"
hdiutil create -volname "QianLi IR" -srcfolder "$STAGE" -ov -format UDZO "dist/QianLi-IR-Mac.dmg"
rm -rf "$STAGE"

# Also a zip of the app, for people who prefer that.
(cd dist && ditto -c -k --keepParent "QianLi IR.app" "QianLi-IR-Mac.zip")
ls -la dist
