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
SIGN=(--sign "$IDENTITY")
if [[ "$IDENTITY" == "-" ]]; then
  echo "signing ad hoc: macOS will ask for Microphone and Accessibility again after each rebuild"
else
  echo "signing as: $IDENTITY"
  # Use the login keychain when the identity is there. A CI runner on the same Mac can
  # put its own locked keychain first in the search list, and codesign then fails with
  # errSecInternalComponent.
  LOGIN="$HOME/Library/Keychains/login.keychain-db"
  if security find-identity -v -p codesigning "$LOGIN" 2>/dev/null | grep -qF "$IDENTITY"; then
    SIGN+=(--keychain "$LOGIN")
  fi
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Keet" "$APP/Contents/MacOS/Keet"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$BIN/FluidAudio_FluidAudio.bundle" "$APP/Contents/Resources/"
# whisper.cpp, for Hebrew. The binary finds it through @executable_path/../Frameworks.
ditto "$BIN/whisper.framework" "$APP/Contents/Frameworks/whisper.framework"

# The framework first, then the app around it, both with the same identity so the
# hardened runtime's library validation accepts it. Ad hoc signatures have no Team ID,
# so library validation would refuse the framework; ad hoc builds turn it off.
ENTITLEMENTS=Resources/Keet.entitlements
if [[ "$IDENTITY" == "-" ]]; then
  ENTITLEMENTS=build/Keet-adhoc.entitlements
  cp Resources/Keet.entitlements "$ENTITLEMENTS"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.cs.disable-library-validation bool true" "$ENTITLEMENTS"
fi
codesign --force --options runtime --timestamp=none "${SIGN[@]}" "$APP/Contents/Frameworks/whisper.framework"
codesign --force --deep --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "${SIGN[@]}" "$APP"
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
