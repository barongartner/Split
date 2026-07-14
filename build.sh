#!/bin/bash
#
# Build Split.app from the Swift sources — no Xcode project needed.
#   ./build.sh            compile + assemble + sign Split.app
#   ./build.sh release    same, then produce dist/Split-<version>.zip and .dmg
#   open Split.app        run it
#
# Users never run this. They download a finished .zip or .dmg from the
# GitHub releases page; this script is for working on Split, and its
# `release` mode is what produces those artifacts.
#
# Signing matters here more than in most apps: the System Audio Recording
# permission is keyed to the signing identity, so an ad-hoc signature (which
# changes every build) would lose the grant on every rebuild. We sign with the
# "Apple Development" certificate from the local keychain, with a secure
# timestamp so the signature stays valid after the certificate expires.
# Override with CODESIGN_ID=<hash or name> to pick a specific identity.
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
if [ "$SIGN_ID" = "-" ]; then
    codesign --force --sign - "$APP"
else
    # --timestamp needs network; fall back to untimestamped rather than fail.
    codesign --force --timestamp --sign "$SIGN_ID" "$APP" 2>/dev/null \
        || codesign --force --sign "$SIGN_ID" "$APP"
fi

echo "Done → $APP"

if [ "${1:-}" = "release" ]; then
    echo "Packaging release artifacts…"
    rm -rf dist && mkdir -p dist

    ditto -c -k --keepParent "$APP" "dist/Split-$VERSION.zip"

    STAGE="$BUILD/dmg"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "Split $VERSION" -srcfolder "$STAGE" -ov -format UDZO \
        "dist/Split-$VERSION.dmg" >/dev/null

    echo "Done → dist/Split-$VERSION.zip, dist/Split-$VERSION.dmg"
fi
