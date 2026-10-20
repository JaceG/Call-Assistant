#!/usr/bin/env bash
# Builds WebRTC's audio processing library (the AEC3 echo canceller) as one
# static library, mac/Vendor/WebRTCAPM.xcframework, plus its headers in
# mac/Vendor/webrtc-apm/include. Both are build output, not committed.
#
# Source: freedesktop's webrtc-audio-processing (BSD-3), pinned below. Its
# build downloads abseil-cpp (Apache-2.0) at a pinned version and hash.
# Needs meson and ninja (brew install meson ninja).
#
#   scripts/build_webrtc_apm.sh          build if missing
#   FORCE=1 scripts/build_webrtc_apm.sh  rebuild
set -euo pipefail

VERSION="v2.1"
REPO="https://gitlab.freedesktop.org/pulseaudio/webrtc-audio-processing.git"

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$ROOT_DIR/mac/Vendor"
SRC="$VENDOR/build/webrtc-audio-processing"
BUILD="$VENDOR/build/apm-build"
PREFIX="$VENDOR/webrtc-apm"
XCFRAMEWORK="$VENDOR/WebRTCAPM.xcframework"

if [[ -d "$XCFRAMEWORK" && "${FORCE:-0}" != "1" ]]; then
  echo "WebRTCAPM.xcframework already built (FORCE=1 to rebuild)"
  exit 0
fi
command -v meson >/dev/null && command -v ninja >/dev/null || {
  echo "Needs meson and ninja: brew install meson ninja"; exit 1; }
# Match the app's minimum macOS (mac/Package.swift), or the linker warns.
export MACOSX_DEPLOYMENT_TARGET=26.0
[[ "${FORCE:-0}" == "1" ]] && rm -rf "$BUILD" "$PREFIX"

if [[ ! -d "$SRC" ]]; then
  git clone --depth 1 --branch "$VERSION" "$REPO" "$SRC"
fi

if [[ ! -d "$BUILD" ]]; then
  (cd "$SRC" && meson setup "$BUILD" --default-library=static --buildtype=release \
    --prefix="$PREFIX" -Dneon=enabled)
fi
ninja -C "$BUILD" install

# One static library: the audio processing module plus the abseil libraries
# it needs (the installed module already contains WebRTC's internal pieces).
MERGED="$PREFIX/lib/libwebrtc-apm.a"
libtool -static -no_warning_for_no_symbols -o "$MERGED" \
  "$PREFIX/lib/libwebrtc-audio-processing-2.a" \
  $(find "$BUILD/subprojects" -name 'libabsl_*.a' | sort)

rm -rf "$XCFRAMEWORK"
xcodebuild -create-xcframework -library "$MERGED" -output "$XCFRAMEWORK" >/dev/null
echo "Built $XCFRAMEWORK ($(du -sh "$MERGED" | cut -f1) static library)"
