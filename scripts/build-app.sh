#!/bin/bash
# Builds build/Keet.app, signs it, and with --install copies it to /Applications.
#
# Signing: set KEET_SIGN_IDENTITY to choose an identity, or "-" for ad hoc. Without it,
# the first "Developer ID Application" identity in your keychain is used, then the first
# "Apple Development" one, then ad hoc. A real identity keeps macOS's Microphone and
# Accessibility grants across rebuilds; with ad hoc signing macOS asks again each time.
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Keet.app"

if [[ -n "${KEET_SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$KEET_SIGN_IDENTITY"
else
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  IDENTITY="$(awk -F'"' '/Developer ID Application/ {print $2; exit}' <<< "$IDENTITIES")"
  [[ -z "$IDENTITY" ]] && IDENTITY="$(awk -F'"' '/Apple Development/ {print $2; exit}' <<< "$IDENTITIES")"
  [[ -z "$IDENTITY" ]] && IDENTITY="-"
fi
if [[ "$IDENTITY" == "-" ]]; then
  echo "signing ad hoc: macOS will ask for Microphone and Accessibility again after each rebuild"
else
  echo "signing as: $IDENTITY"
fi

swift build -c release --product Keet
BIN="$(swift build -c release --show-bin-path)"

if [[ ! -f build/AppIcon.icns ]]; then
  ICONSET="build/AppIcon.iconset"
  mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon_1024.png >/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Keet" "$APP/Contents/MacOS/Keet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN/FluidAudio_FluidAudio.bundle" "$APP/Contents/Resources/"

codesign --force --deep --options runtime --timestamp=none \
  --entitlements Resources/Keet.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  if pgrep -xq Keet; then
    osascript -e 'tell application id "agency.ziplyne.keet" to quit' || true
    sleep 1
  fi
  rm -rf /Applications/Keet.app
  ditto "$APP" /Applications/Keet.app
  echo "installed /Applications/Keet.app"
fi
