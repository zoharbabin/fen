#!/usr/bin/env bash
#
# build-app.sh — assemble a macOS .app bundle from the SwiftPM build.
#
# Plain build (unsigned, runs locally):
#     ./scripts/build-app.sh
#
# Signed + notarized release (needs an Apple Developer account):
#     SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#     NOTARY_PROFILE="fen-notary" \
#     ./scripts/build-app.sh
#
# Environment overrides:
#     APP_NAME        App/display name           (default: Fen)
#     BUNDLE_ID       Bundle identifier          (default: com.zoharbabin.fen)
#     VERSION         Marketing version string   (default: git tag/short SHA)
#     CONFIG          debug | release            (default: release)
#     SIGN_IDENTITY   Developer ID identity      (default: ad-hoc, i.e. unsigned for distribution)
#     NOTARY_PROFILE  notarytool keychain profile to notarize + staple (optional)
#
set -euo pipefail

APP_NAME="${APP_NAME:-Fen}"
BUNDLE_ID="${BUNDLE_ID:-com.zoharbabin.fen}"
CONFIG="${CONFIG:-release}"
PRODUCT="Fen"                     # SwiftPM executable product (see Package.swift)
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

# SwiftPM resource bundles (themes, styles, templates, extensions).
# Bundles live in Contents/Resources/ (Bundle.main.resourceURL), where codesign
# expects nested bundles. Our vendored Highlightr resolves against resourceURL.
# macOS 26+ requires an Info.plist in each bundle for Bundle(url:) to recognise
# it as a valid bundle package; SPM doesn't generate one, so we inject one here.
shopt -s nullglob
for b in "$BIN_PATH"/*.bundle; do
    bname="$(basename "$b" .bundle)"
    dest="$CONTENTS/Resources/$(basename "$b")"
    cp -R "$b" "$dest"
    if [ ! -f "$dest/Info.plist" ]; then
        /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string BNDL" \
            -c "Add :CFBundleIdentifier string $BUNDLE_ID.$bname" \
            "$dest/Info.plist" >/dev/null
    fi
done
shopt -u nullglob

# Code signing identity — auto-detect a Developer ID if none was provided. Resolved here,
# ahead of the FenQuickLook build below, since that build needs to sign the extension with
# the same identity the main app will use.
if [ -z "${SIGN_IDENTITY:-}" ]; then
    DETECTED="$(security find-identity -v -p codesigning 2>/dev/null \
        | grep "Developer ID Application" | head -1 \
        | sed -E 's/.*"(.*)".*/\1/')"
    if [ -n "$DETECTED" ]; then
        SIGN_IDENTITY="$DETECTED"
        echo "==> Auto-detected signing identity: $SIGN_IDENTITY"
    fi
fi

# FenQuickLook.appex — SwiftPM has no app-extension concept, so this can't come from
# `swift build` above. `project.yml` declares the extension target and embeds it in the
# FenMacOSApp scheme; build that scheme via the Xcode project xcodegen generates from it,
# then lift just the built .appex out. (Building FenQuickLook as an isolated `-target`
# reliably fails with DerivedData path collisions against SPM checkouts; building the
# whole scheme, as a real `xcodebuild test` run already does elsewhere in this repo, does
# not.) See issue #114.
echo "==> Building FenQuickLook.appex…"
command -v xcodegen >/dev/null || {
    echo "!! xcodegen not found (brew install xcodegen)" >&2
    exit 1
}
xcodegen generate --spec "$ROOT/project.yml" --project "$ROOT" >/dev/null

XC_CONFIG="Release"
[ "$CONFIG" = "debug" ] && XC_CONFIG="Debug"
XC_DD="$(mktemp -d)"
trap 'rm -rf "$XC_DD"' EXIT

if [ -n "${SIGN_IDENTITY:-}" ]; then
    # Notarization requires hardened runtime + a secure timestamp on every signed
    # Mach-O in the bundle, extension included — pass them explicitly here since
    # xcodebuild, not this script, is what signs the extension.
    XC_SIGN_ARGS=(
        CODE_SIGN_STYLE=Manual
        "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
        ENABLE_HARDENED_RUNTIME=YES
        "OTHER_CODE_SIGN_FLAGS=--timestamp"
    )
else
    # No identity to sign with yet — this script's own ad-hoc signing step below
    # handles the extension once it's embedded, same as it does for the main app.
    XC_SIGN_ARGS=(CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO)
fi

xcodebuild build \
    -scheme FenMacOSApp -project "$ROOT/FenUITesting.xcodeproj" \
    -configuration "$XC_CONFIG" -destination "platform=macOS" \
    -derivedDataPath "$XC_DD" \
    "MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$BUILD_NUM" \
    "${XC_SIGN_ARGS[@]}"

BUILT_APPEX="$XC_DD/Build/Products/$XC_CONFIG/$APP_NAME.app/Contents/PlugIns/FenQuickLook.appex"
if [ ! -d "$BUILT_APPEX" ]; then
    echo "!! FenQuickLook.appex was not produced by the Xcode build" >&2
    exit 1
fi
mkdir -p "$CONTENTS/PlugIns"
cp -R "$BUILT_APPEX" "$CONTENTS/PlugIns/FenQuickLook.appex"
rm -rf "$XC_DD"
trap - EXIT

# App icon
iconutil -c icns "$ROOT/macOS/AppIcon.iconset" -o "$CONTENTS/Resources/AppIcon.icns"

# Document icon (Finder icon for .md files, referenced by
# CFBundleDocumentTypes:0:CFBundleTypeIconFile in macOS/Info.plist)
iconutil -c icns "$ROOT/macOS/DocumentIcon.iconset" -o "$CONTENTS/Resources/DocumentIcon.icns"

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
set_key NSHumanReadableCopyright "Fen — based on MacDown © 2014 Tzu-ping Chung. MIT License."

# PkgInfo
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Code signing. FenQuickLook.appex (if present) is signed first, with its own
# entitlements — Apple requires nested code signed before the bundle that embeds it.
# The outer app is then signed WITHOUT --deep: --deep would re-sign the extension using
# the main app's entitlements instead of its own, breaking its sandboxed identity. The
# ad-hoc branch below still uses --deep since there's only one (shared) identity there.
if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "==> Signing with: $SIGN_IDENTITY"
    if [ -d "$CONTENTS/PlugIns/FenQuickLook.appex" ]; then
        codesign --force --options runtime --timestamp \
            --entitlements "$ROOT/FenQuickLook/FenQuickLook.entitlements" \
            --sign "$SIGN_IDENTITY" "$CONTENTS/PlugIns/FenQuickLook.appex"
    fi
    codesign --force --options runtime --timestamp \
        --entitlements "$ROOT/macOS/Fen.entitlements" \
        --sign "$SIGN_IDENTITY" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
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
