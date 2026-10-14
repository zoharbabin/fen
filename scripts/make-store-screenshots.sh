#!/bin/bash
# Takes the App Store screenshots from the running apps and writes them to assets/store/screenshots.
#
#   scripts/make-store-screenshots.sh [output-dir]
#
# Each part is optional: PLATFORMS="mac phone pad" is the default. It needs Xcode, xcodegen, and a local
# Ollama with gemma4 and embeddinggemma for the Ask pictures. Everything shown comes from
# assets/store/sample-workspace. Nothing of yours appears: the Mac app runs on a throwaway home folder,
# and the simulators get a fresh copy of the sample notes.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=${1:-assets/store/screenshots}
PLATFORMS=${PLATFORMS:-"mac phone pad"}
PHONE_NAME=${PHONE_NAME:-"iPhone 17 Pro Max"}
PAD_NAME=${PAD_NAME:-"iPad Pro 13-inch (M5)"}
# Set TESTS to run one test, for example TESTS=FeniOSUITests/StoreScreenshotsUITests/testAsk.
TESTS=${TESTS:-FeniOSUITests/StoreScreenshotsUITests}
# Set RAW to a folder to keep earlier captures and add to them.
RAW=${RAW:-$(mktemp -d /tmp/fen-store-raw.XXXXXX)}
mkdir -p "$RAW"
DERIVED=/tmp/fen-store-ios
SHARED=/Users/Shared/Trailhead
trap 'rm -rf "$SHARED"' EXIT

xcodegen generate >/dev/null

shoot_mac() {
    TEST_RUNNER_FEN_STORE_SHOTS_DIR=$RAW nice -n 10 xcodebuild test -scheme FenMacOSApp \
        -project FenUITesting.xcodeproj -destination 'platform=macOS' \
        -only-testing:FenMacOSUITests/StoreScreenshotsUITests | tail -3
}

# shoot_sim <device name>
shoot_sim() {
    local udid
    udid=$(xcrun simctl list devices available -j | python3 -c '
import json, sys
name = sys.argv[1]
for devices in json.load(sys.stdin)["devices"].values():
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); sys.exit()
sys.exit("no simulator named " + name)' "$1")
    xcrun simctl shutdown all
    xcrun simctl boot "$udid"
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time 9:41 --batteryState charged --batteryLevel 100 \
        --cellularBars 4 --wifiBars 3 --operatorName ""

    nice -n 10 xcodebuild build-for-testing -scheme FeniOSApp -project FenUITesting.xcodeproj \
        -destination "id=$udid" -derivedDataPath "$DERIVED" | tail -1
    xcrun simctl install "$udid" "$DERIVED/Build/Products/Debug-iphonesimulator/Fen.app"

    # The notes open from Fen's folder. The workspace points at a shared folder, because the app's own
    # folder gets a new path each time the test runner reinstalls the app.
    local data
    data=$(xcrun simctl get_app_container "$udid" com.zoharbabin.fen data)
    mkdir -p "$data/Documents" "$data/Library/.fen"
    cp assets/store/sample-workspace/*.md "$data/Documents/"
    rm -rf "$SHARED"
    cp -R assets/store/sample-workspace "$SHARED"
    python3 - "$data" "$SHARED" <<'P'
import json, sys, uuid
data, shared = sys.argv[1:]
settings = {
    "agentBranches": "perAgent", "aiDataAccess": "localProvidersOnly", "approvalMode": "ask",
    "clonedByFen": False, "enrichOnSave": False, "enrichSchedule": "off", "excludeGlobs": [],
    "includeGlobs": ["**/*.md", "**/*.markdown", "**/*.mdx", "**/*.txt"], "maxFileBytes": 2000000,
    "mcpAccess": "disabled", "pushesAIChanges": False,
    "writePolicy": {"autoApproveConfirmed": False, "autoApproveMinConfidence": 0.8, "autoApproveReplacing": [],
                    "maxChangedFraction": 0.5, "maxFilesPerRun": 20, "overrides": []},
}
workspace = {"id": str(uuid.uuid4()).upper(), "name": "Trailhead", "addedAt": "2026-10-01T09:00:00Z",
             "path": shared, "settings": settings}
json.dump({"version": 1, "workspaces": [workspace]}, open(data + "/Library/.fen/workspaces.json", "w"))
provider = {"id": str(uuid.uuid4()).upper(), "kind": "ollama", "name": "Ollama",
            "baseURL": "http://localhost:11434", "model": "gemma4:latest"}
json.dump({"version": 1, "providers": [provider], "selectedID": provider["id"]},
          open(data + "/Library/.fen/ai-providers.json", "w"))
P
    TEST_RUNNER_FEN_STORE_SHOTS_DIR=$RAW nice -n 10 xcodebuild test-without-building -scheme FeniOSApp \
        -project FenUITesting.xcodeproj -destination "id=$udid" -derivedDataPath "$DERIVED" \
        -only-testing:"$TESTS" | tail -3
    xcrun simctl status_bar "$udid" clear
    xcrun simctl shutdown "$udid"
}

for platform in $PLATFORMS; do
    case $platform in
        mac) shoot_mac ;;
        phone) shoot_sim "$PHONE_NAME" ;;
        pad) shoot_sim "$PAD_NAME" ;;
        *) echo "unknown platform: $platform" >&2; exit 2 ;;
    esac
done

swift scripts/compose-store-screenshots.swift "$RAW" "$OUT"
echo "raw captures: $RAW"
