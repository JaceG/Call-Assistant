#!/usr/bin/env bash
# Builds the Mac app and wraps it into a signed bundle at mac/dist/CallAssistant.app.
#
# Signing uses CODESIGN_IDENTITY if set, otherwise the first "Apple Development"
# identity in the keychain. A stable signature keeps the microphone and
# system-audio permissions from resetting on every rebuild.
#
#   scripts/build_mac_app.sh             release build
#   CONFIG=debug scripts/build_mac_app.sh
#   SKIP_SIGN=1 scripts/build_mac_app.sh  unsigned (permissions won't stick)
#
# Adapted from OpenOats' scripts/build_swift_app.sh (MIT), see THIRD_PARTY_NOTICES.md.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAC_DIR="$ROOT_DIR/mac"
CONFIG="${CONFIG:-release}"
APP_NAME="CallAssistant"
APP_DIR="$MAC_DIR/dist/$APP_NAME.app"

echo "=== Building $APP_NAME ($CONFIG) ==="
cd "$MAC_DIR"
swift build -c "$CONFIG"
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BINARY="$BIN_DIR/$APP_NAME"
[[ -f "$BINARY" ]] || { echo "Build failed: no binary at $BINARY"; exit 1; }

echo "=== Bundling $APP_DIR ==="
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"
cp "$MAC_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
echo -n "APPL????" > "$APP_DIR/Contents/PkgInfo"

# Let dyld find anything embedded in Contents/Frameworks.
if ! otool -l "$APP_DIR/Contents/MacOS/$APP_NAME" | grep -Fq "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/$APP_NAME"
fi

# SwiftPM resource bundles from dependencies.
BUNDLES=0
while IFS= read -r -d '' bundle; do
  cp -R "$bundle" "$APP_DIR/Contents/Resources/"
  BUNDLES=$((BUNDLES + 1))
done < <(find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -type d -print0)
echo "Copied $BUNDLES resource bundle(s)"

if [[ "${SKIP_SIGN:-0}" == "1" ]]; then
  echo "Skipping code signing"
  exit 0
fi

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning | grep '"Apple Development' | head -1 | sed 's/.*"\(.*\)"/\1/' || true)"
fi
[[ -n "$CODESIGN_IDENTITY" ]] || { echo "No Apple Development identity found; set CODESIGN_IDENTITY or SKIP_SIGN=1"; exit 1; }

echo "=== Signing ==="
# Resource bundles first (inside-out), then the app. No secure timestamp:
# these are local builds, and the timestamp needs Apple's server.
find "$APP_DIR/Contents/Resources" -maxdepth 1 -name "*.bundle" -type d -exec \
  codesign --force --options runtime --sign "$CODESIGN_IDENTITY" {} \;
codesign --force --options runtime \
  --entitlements "$MAC_DIR/Resources/CallAssistant.entitlements" \
  --sign "$CODESIGN_IDENTITY" \
  "$APP_DIR"
codesign --verify --strict "$APP_DIR"
echo "Signed and verified: $APP_DIR"
