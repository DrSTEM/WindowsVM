#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Windows VM.app"
codesign --verify --deep --strict "$APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="dist/Windows-VM-${VERSION}-local.dmg"
mkdir -p dist
STAGE="$(mktemp -d "${TMPDIR:-/private/tmp/}windows-vm-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Windows VM.app"
cp README.md "$STAGE/README.md"
cp LICENSE NOTICE "$STAGE/"
mkdir -p "$STAGE/docs/assets"
for guide in INSTALLATION USAGE UPDATING ARCHITECTURE TROUBLESHOOTING STATUS; do
  cp "docs/$guide.md" "$STAGE/docs/"
done
cp docs/assets/banner.svg "$STAGE/docs/assets/"
cp CONTRIBUTING.md CHANGELOG.md SECURITY.md "$STAGE/"
ditto ThirdParty "$STAGE/ThirdParty"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Windows VM — Local Build" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT"
hdiutil verify "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"
echo "Packaged $OUTPUT (local development build only)"
