#!/bin/sh
# Runs the workspace UI tests against the sandboxed Mac App Store build (issue #40).
# The build is ad hoc signed with macOS/FenAppStore.entitlements and checks that folder grants, the
# index, search and the saved folder bookmark all work inside the sandbox.
# The sandbox keeps Fen's data in the app container, so the script sets your existing ~/.fen aside there
# and puts it back when it ends. Usage: scripts/test-appstore-sandbox.sh
set -eu
cd "$(dirname "$0")/.."
DD=/tmp/fen-appstore-dd
FEN="$HOME/Library/Containers/com.zoharbabin.fen/Data/.fen"
ASIDE="$FEN.before-sandbox-test"
[ ! -e "$ASIDE" ] || { echo "$ASIDE exists from an earlier run. Move it back to $FEN first." >&2; exit 1; }
restore() { pkill -x Fen 2>/dev/null || true; rm -rf "$FEN"; [ ! -e "$ASIDE" ] || mv "$ASIDE" "$FEN"; }
trap restore EXIT
pkill -x Fen 2>/dev/null || true
[ ! -e "$FEN" ] || mv "$FEN" "$ASIDE"

xcodegen generate >/dev/null
# The UI test target builds the unsandboxed app. Swap in the store build before the tests run.
xcodebuild build-for-testing -scheme FenMacOSApp -project FenUITesting.xcodeproj -destination 'platform=macOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO >/dev/null
xcodebuild build -scheme FenMacOSAppStore -project FenUITesting.xcodeproj -destination 'platform=macOS' \
    -derivedDataPath "$DD/store" CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= >/dev/null
rm -rf "$DD/Build/Products/Debug/Fen.app"
cp -R "$DD/store/Build/Products/Debug/Fen.app" "$DD/Build/Products/Debug/Fen.app"
codesign -d --entitlements - "$DD/Build/Products/Debug/Fen.app" 2>&1 | grep -q app-sandbox \
    || { echo "The store build is not sandboxed." >&2; exit 1; }
[ ! -e "$DD/Build/Products/Debug/Fen.app/Contents/Frameworks/Sparkle.framework" ] \
    || { echo "The store build contains Sparkle." >&2; exit 1; }

STATUS=0
for TEST in $(grep -o 'func test[A-Za-z]*' UITests/FenUITests/WorkspaceControlsUITests.swift | cut -d' ' -f2); do
    pkill -x Fen 2>/dev/null || true
    rm -rf "$FEN"   # every test starts with no workspaces, as it does outside the sandbox
    TEST_RUNNER_FEN_SANDBOXED=1 xcodebuild test-without-building -scheme FenMacOSApp -project FenUITesting.xcodeproj -destination 'platform=macOS' \
        -derivedDataPath "$DD" -only-testing:FenMacOSUITests/WorkspaceControlsUITests/"$TEST" \
        CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "Test Case.*(passed|failed)|error:" || STATUS=1
done
exit $STATUS
