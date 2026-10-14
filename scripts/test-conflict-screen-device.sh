#!/bin/bash
# Tests the iOS GitHub conflict screen (issue #62) on a real, unlocked iPhone or iPad.
# Needs no token: it fakes a sync state against the public zoharbabin/fen repository.
# Leaves a "fen-conflict-demo" folder and workspace on the device. Remove them in Files and Fen.
#
#   scripts/test-conflict-screen-device.sh <device UDID>
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <device UDID>" >&2; exit 2; }
DEVICE=$1
BUNDLE=com.zoharbabin.fen
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

copy_to() { xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier $BUNDLE --source "$1" --destination "$2" > /dev/null; }
copy_from() { xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier $BUNDLE --source "$1" --destination "$2" > /dev/null; }
run_phase() {
    TEST_RUNNER_FEN_CONFLICT_PHASE=$1 nice -n 10 xcodebuild test -project FenUITesting.xcodeproj -scheme FeniOSApp \
        -destination "id=$DEVICE" -allowProvisioningUpdates -derivedDataPath /tmp/fen-ios-device \
        -only-testing:"FeniOSUITests/ConflictScreenDeviceUITests/$2" | tail -3
}

xcodegen generate > /dev/null
printf '# My local edit\n\nI changed this note on my phone.\n' > "$WORK/README.md"
copy_to "$WORK/README.md" Documents/fen-conflict-demo/README.md
run_phase grant testGrantTheDemoFolder

copy_from Library/.fen/workspaces.json "$WORK/workspaces.json"
ID=$(python3 -I -c "
import json, sys
found = [w for w in json.load(open(sys.argv[1]))['workspaces'] if w['name'] == 'fen-conflict-demo']
print(found[-1]['id'].lower())" "$WORK/workspaces.json")

# GitHub's current head, and a base hash that matches neither the local note nor GitHub's.
HEAD=$(gh api repos/zoharbabin/fen/commits/master --jq '.sha + " " + .commit.tree.sha')
BLOB=$(gh api repos/zoharbabin/fen/contents/README.md --jq .sha)
python3 -I - "$WORK/github-mirror.json" $HEAD $BLOB << 'PY'
import json, sys
out, commit, tree, blob = sys.argv[1:]
json.dump({"owner": "zoharbabin", "name": "fen", "branch": "master", "commit": commit, "tree": tree,
           "files": {"README.md": "0" * 39 + "1"}, "conflicts": {"README.md": blob},
           "syncedAt": "2026-01-01T00:00:00Z"}, open(out, "w"))
PY
copy_to "$WORK/github-mirror.json" "Library/.fen/workspaces/$ID/github-mirror.json"
run_phase resolve testConflictScreenListsTheNoteAndUseGitHubsSettlesIt
