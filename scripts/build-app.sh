#!/usr/bin/env bash
#
# build-app.sh — assemble a macOS .app bundle from the SwiftPM build.
#
# Plain build (unsigned, runs locally):
#     ./scripts/build-app.sh
#
# Signed + notarized release (needs an Apple Developer account):
#     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     NOTARY_PROFILE="macdown-notary" \
#     ./scripts/build-app.sh
#
# Environment overrides:
#     APP_NAME        App/display name           (default: MacDown)
#     BUNDLE_ID       Bundle identifier          (default: com.mfbergmann.macdown)
#     VERSION         Marketing version string   (default: git tag/short SHA)
#     CONFIG          debug | release            (default: release)
#     SIGN_IDENTITY   Developer ID identity      (default: ad-hoc, i.e. unsigned for distribution)
#     NOTARY_PROFILE  notarytool keychain profile to notarize + staple (optional)
#
set -euo pipefail

APP_NAME="${APP_NAME:-MacDown}"
BUNDLE_ID="${BUNDLE_ID:-com.mfbergmann.macdown}"
CONFIG="${CONFIG:-release}"
PRODUCT="MacDownSwift"            # SwiftPM executable product (see Package.swift)
MIN_MACOS="15.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
CONTENTS="$APP/Contents"

# Marketing version: a v-prefixed git tag if present (e.g. v1.2.0 -> 1.2.0),
# otherwise 0.0.0-dev. App Store-style numeric build from the commit count.
VERSION="${VERSION:-$(git -C "$ROOT" describe --tags --abbrev=0 2>/dev/null || echo 0.0.0-dev)}"
VERSION="${VERSION#v}"
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building $PRODUCT ($CONFIG)…"
swift build -c "$CONFIG" --product "$PRODUCT"
BIN_PATH="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> Assembling $APP_NAME.app (version $VERSION, build $BUILD_NUM)…"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Executable
cp "$BIN_PATH/$PRODUCT" "$CONTENTS/MacOS/$APP_NAME"
chmod +x "$CONTENTS/MacOS/$APP_NAME"

# SwiftPM resource bundles (themes, styles, templates, extensions)
shopt -s nullglob
for b in "$BIN_PATH"/*.bundle; do
    cp -R "$b" "$CONTENTS/Resources/"
done
shopt -u nullglob

# App icon
iconutil -c icns "$ROOT/macOS/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

# Info.plist — start from the macOS source plist, then patch identity/version.
PLIST="$CONTENTS/Info.plist"
cp "$ROOT/macOS/Info.plist" "$PLIST"
pb() { /usr/libexec/PlistBuddy -c "$1" "$PLIST"; }
set_key() { pb "Set :$1 $2" 2>/dev/null || pb "Add :$1 string $2"; }
set_key CFBundleExecutable "$APP_NAME"
set_key CFBundleName "$APP_NAME"
set_key CFBundleDisplayName "$APP_NAME"
set_key CFBundleIdentifier "$BUNDLE_ID"
set_key CFBundleIconFile "AppIcon"
set_key CFBundleShortVersionString "$VERSION"
set_key CFBundleVersion "$BUILD_NUM"
set_key CFBundleInfoDictionaryVersion "6.0"
set_key LSMinimumSystemVersion "$MIN_MACOS"
set_key NSHumanReadableCopyright "MacDown © 2014 Tzu-ping Chung. Swift rewrite by Michael F Bergmann. MIT License."

# PkgInfo
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Code signing — auto-detect a Developer ID if none was provided.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    DETECTED="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/')"
    if [ -n "$DETECTED" ]; then
        SIGN_IDENTITY="$DETECTED"
        echo "==> Auto-detected signing identity: $SIGN_IDENTITY"
    fi
fi

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --entitlements "$ROOT/macOS/MacDown.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --strict --verbose=2 "$APP"
else
    echo "==> No SIGN_IDENTITY set — applying ad-hoc signature (local use only)."
    codesign --force --deep --sign - "$APP"
fi

# Notarization (optional)
if [ -n "${NOTARY_PROFILE:-}" ]; then
    if [ -z "${SIGN_IDENTITY:-}" ]; then
        echo "!! Notarization requires a Developer ID SIGN_IDENTITY. Skipping." >&2
    else
        ZIP="$DIST/$APP_NAME.zip"
        echo "==> Submitting to Apple notary service…"
        ditto -c -k --keepParent "$APP" "$ZIP"
        xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
        echo "==> Stapling ticket…"
        xcrun stapler staple "$APP"
        rm -f "$ZIP"
    fi
fi

echo "==> Done: $APP"
