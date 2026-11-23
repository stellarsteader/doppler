#!/usr/bin/env bash
# Builds "Doppler.app" into apps/macos/build/. No Apple Developer account needed.
#   ./build.sh            build
#   ./build.sh --install  build and copy to /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Doppler.app"
IDENTITY="${SIGN_IDENTITY:-Doppler Local}"

swift build -c release --disable-sandbox
BIN="$(swift build -c release --disable-sandbox --show-bin-path)/Doppler"

if [ ! -f build/AppIcon.icns ] || [ -n "$(find Scripts/make_icon.swift ../../assets/logo -type f -newer build/AppIcon.icns)" ]; then
  echo "==> Drawing app icon"
  mkdir -p build/AppIcon.iconset
  swift Scripts/make_icon.swift ../../assets/logo build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Doppler"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Sounds/*.wav "$APP/Contents/Resources/"

# No -v: a self-signed certificate isn't "valid" (trusted) by default, but codesign can still
# use it, and that's all macOS needs to keep permissions across rebuilds.
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "==> Signing with \"$IDENTITY\""
  # No hardened runtime: that would need an audio-input entitlement and only matters for notarization.
  codesign --force --deep --sign "$IDENTITY" "$APP"
else
  echo "==> Signing ad hoc (no \"$IDENTITY\" identity found)"
  codesign --force --deep --sign - "$APP"
fi

if [ "${1:-}" = "--install" ]; then
  echo "==> Installing to /Applications"
  # Other apps share this name, so never replace one that isn't this app.
  INSTALLED="/Applications/Doppler.app"
  if [ -d "$INSTALLED" ] && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED/Contents/Info.plist" 2>/dev/null)" != "dev.doppler.mac" ]; then
    echo "$INSTALLED is a different app, so it was not replaced." >&2
    exit 1
  fi
  pkill -x Doppler 2>/dev/null || true
  rm -rf "$INSTALLED"
  cp -R "$APP" /Applications/
  echo "Done. Open it with:  open \"/Applications/Doppler.app\""
else
  echo "Done: $APP"
fi
