#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Windows VM.app"
frontend_only=false
case "${1:-}" in
  "") ;;
  --frontend) frontend_only=true ;;
  *) echo 'Usage: scripts/build-app.sh [--frontend]' >&2; exit 2 ;;
esac
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/module-cache
if [ ! -d Runtime/Frameworks/dxmt-native.framework ] || [ ! -x Runtime/bin/VMRenderServer ]; then
  echo 'Runtime missing: run bash scripts/setup.sh first.' >&2
  exit 1
fi
if $frontend_only; then
  if [ ! -f build/spice/build-script.sha256 ] ||
     ! shasum -a 256 -c build/spice/build-script.sha256 >/dev/null ||
     { [ -f Runtime/setup-lock.json ] && ! cmp -s Runtime/setup-lock.json "$APP/Contents/Resources/Runtime/setup-lock.json"; } ||
     [ ! -f build/spice/Objects/CSMetalRenderer.o ] ||
     [ ! -f "$APP/Contents/Resources/CocoaSpiceShaders.metal" ] ||
     [ ! -x "$APP/Contents/MacOS/VMEngine" ]; then
    echo 'Run the full build first to prepare CocoaSpice and the VM runtime.' >&2
    exit 1
  fi
else
  python3 scripts/build-spice.py "$APP/Contents/Resources"
  shasum -a 256 scripts/build-spice.py scripts/runtime-lock.json scripts/runtime-probe.c scripts/hypervisor.entitlements Runtime/manifest.json > build/spice/build-script.sha256
fi
xcrun swiftc -swift-version 5 -O -whole-module-optimization -parse-as-library \
  Sources/WindowsVM/*.swift build/spice/Objects/*.o -o "$APP/Contents/MacOS/WindowsVM" \
  -module-cache-path build/module-cache -target arm64-apple-macos14.0 \
  -I build/spice/Modules/CocoaSpiceNoUsb -I build/spice/Modules/CocoaSpiceRenderer \
  -F Runtime/Frameworks -framework spice-client-glib-2.0.8 -framework glib-2.0.0 -framework gobject-2.0.0 \
  -framework SwiftUI -framework AppKit -framework Metal -framework MetalKit -framework IOSurface -framework CoreImage \
  -Xlinker -rpath -Xlinker @executable_path/../Resources/Runtime/Frameworks
cp scripts/Info.plist "$APP/Contents/Info.plist"
if ! $frontend_only; then
  xcrun clang scripts/runtime-probe.c -o "$APP/Contents/MacOS/VMEngine" -Wl,-rpath,@executable_path/../Resources/Runtime/Frameworks -mmacosx-version-min=14.0
  /usr/bin/ditto Runtime "$APP/Contents/Resources/Runtime"
  /usr/bin/ditto ThirdParty "$APP/Contents/Resources/ThirdParty"
  codesign --force --sign - --entitlements scripts/hypervisor.entitlements "$APP/Contents/MacOS/VMEngine"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP"
