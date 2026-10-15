#!/bin/sh
# Runs ShareInboxUITests on a simulator (issue #43). The app is signed ad hoc so it gets its App Group
# container, and the test writes into that container's Inbox folder.
# Usage: scripts/test-share-inbox.sh [simulator-udid]   (default: the booted simulator)
set -eu
cd "$(dirname "$0")/.."
# The llama.cpp binary has no simulator slice (see Package.swift).
export FEN_WITHOUT_LLAMA=1
UDID="${1:-booted}"
[ "$UDID" = booted ] && UDID="$(xcrun simctl list devices booted | sed -n 's/.*(\([0-9A-F-]\{36\}\)) (Booted).*/\1/p' | head -1)"
[ -n "$UDID" ] || { echo "Boot a simulator first, or pass its UDID." >&2; exit 1; }
xcodegen generate >/dev/null
SIGN="CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="
DEST="platform=iOS Simulator,id=$UDID"
# Build and install first, so the group container exists before the test asks for it.
xcodebuild build-for-testing -scheme FeniOSApp -project FenUITesting.xcodeproj -destination "$DEST" $SIGN >/dev/null
APP="$(xcodebuild -scheme FeniOSApp -project FenUITesting.xcodeproj -destination "$DEST" -showBuildSettings $SIGN \
    | sed -n 's/^ *TARGET_BUILD_DIR = //p' | head -1)/Fen.app"
xcrun simctl install "$UDID" "$APP"
xcrun simctl launch "$UDID" com.zoharbabin.fen >/dev/null
xcrun simctl terminate "$UDID" com.zoharbabin.fen
GROUP="$(xcrun simctl get_app_container "$UDID" com.zoharbabin.fen groups | sed -n 's/^group.com.zoharbabin.fen\t//p')"
[ -n "$GROUP" ] || { echo "The app has no App Group container. Is it signed with the entitlement?" >&2; exit 1; }
TEST_RUNNER_FEN_SHARE_INBOX="$GROUP/Inbox" xcodebuild test-without-building -scheme FeniOSApp -project FenUITesting.xcodeproj \
    -destination "$DEST" -only-testing:FeniOSUITests/ShareInboxUITests $SIGN
