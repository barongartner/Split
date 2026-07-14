#!/bin/bash
#
# Build Split.app from the Swift sources — no Xcode project needed.
#   ./build.sh          compile + assemble + sign Split.app
#   open Split.app      run it
#
# Signing matters here more than in most apps: the System Audio Recording
# permission is keyed to the signing identity, so an ad-hoc signature (which
# changes every build) would lose the grant on every rebuild. We sign with the
# "Apple Development" certificate from the local keychain. Override with
# CODESIGN_ID=<hash or name> if you have more than one and want a specific one.
#
set -euo pipefail
cd "$(dirname "$0")"

APP="Split.app"
BIN="Split"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macosx14.4"
BUILD=".build"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"

SIGN_ID="${CODESIGN_ID:-$(security find-identity -v -p codesigning | awk '/Apple Development/{print $2; exit}')}"
if [ -z "$SIGN_ID" ]; then
    echo "warning: no Apple Development certificate found — falling back to ad-hoc signing." >&2
    echo "warning: the audio permission will reset on every rebuild until you sign into Xcode with an Apple ID." >&2
    SIGN_ID="-"
fi

rm -rf "$APP" "$BUILD"
mkdir -p "$BUILD"

echo "Compiling Split $VERSION ($TARGET)…"
find Sources -name '*.swift' -print0 | xargs -0 swiftc -O -swift-version 5 -parse-as-library -target "$TARGET" \
    -framework SwiftUI -framework AppKit -framework CoreAudio -framework AudioToolbox -framework ServiceManagement \
    -o "$BUILD/$BIN"

echo "Assembling $APP…"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/$BIN" "$APP/Contents/MacOS/$BIN"
cp Info.plist "$APP/Contents/Info.plist"
[ -f Split.icns ] && cp Split.icns "$APP/Contents/Resources/Split.icns" || true

echo "Signing ($SIGN_ID)…"
codesign --force --sign "$SIGN_ID" "$APP"

echo "Done → $APP"
