#!/bin/bash
# Checks iCloud sync and version history between this Mac and a real iPhone or iPad (issue #59).
# The Mac saves a marker line into a Markdown file in iCloud Drive, from Fen. The device then opens
# the file in Fen and lists its versions. Both print what they see. The script puts the file's
# original text back at the end (a plain copy, which adds one more version).
# Needs: the same iCloud account on both, iCloud Drive on, the device unlocked, Terminal allowed to read iCloud Drive.
#
#   scripts/test-icloud-device.sh <device UDID> [file name without .md, default test-file]
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 <device UDID> [file name]" >&2; exit 2; }
DEVICE=$1
NAME=${2:-test-file}
FILE="$HOME/Library/Mobile Documents/com~apple~CloudDocs/$NAME.md"
[ -f "$FILE" ] || { echo "no $FILE" >&2; exit 2; }
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$FILE" "$WORK/original.md"
cd "$(dirname "$0")/.."
xcodegen generate > /dev/null

echo "== Mac: edit and save in Fen"
LOG=$WORK/mac.log
TEST_RUNNER_FEN_ICLOUD_FILE="$FILE" nice -n 10 xcodebuild test -project FenUITesting.xcodeproj -scheme FenMacOSApp \
    -destination 'platform=macOS' -only-testing:FenMacOSUITests/ICloudDocumentUITests > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }
MARKER=$(grep -o 'fen-icloud-check-[0-9A-F]*' "$LOG" | head -1)
[ -n "$MARKER" ] || { echo "no marker in the Mac run" >&2; exit 1; }
echo "marker $MARKER"
swift scripts/check-icloud-file.swift "$FILE" "$WORK/original.md" --keep | sed 's/^/mac: /' || true

echo "== Device: open the file and list versions"
TEST_RUNNER_FEN_ICLOUD_MARKER=$MARKER TEST_RUNNER_FEN_ICLOUD_NAME=$NAME nice -n 10 xcodebuild test \
    -project FenUITesting.xcodeproj -scheme FeniOSApp -destination "id=$DEVICE" -allowProvisioningUpdates \
    -derivedDataPath /tmp/fen-ios-device -only-testing:FeniOSUITests/ICloudDeviceUITests > /tmp/fen-icloud-ios.log 2>&1 || true
grep -E 'ICLOUD-IOS|Test Case .*(passed|failed)|error:' /tmp/fen-icloud-ios.log || tail -30 /tmp/fen-icloud-ios.log

cp "$WORK/original.md" "$FILE"
echo "original text restored"
