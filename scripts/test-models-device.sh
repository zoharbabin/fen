#!/bin/bash
# Runs one downloaded model on a real iPhone or iPad and prints load time, speed, peak memory and heat
# (issue #234). It builds a debug Fen, copies the model file into the app, launches it with
# FEN_MODEL_SELFTEST=<model id> and prints the lines the app reports (`DeviceSelfTest`). No UI is driven.
# The app deletes the copy when the run ends. Needs the device unlocked and a folder that holds the catalog files.
#
#   scripts/test-models-device.sh <device UDID> <model id> <folder with the .gguf files>
set -euo pipefail
[ $# -eq 3 ] || { echo "usage: $0 <device UDID> <model id> <model folder>" >&2; exit 2; }
DEVICE=$1; MODEL=$2; FOLDER=$3
BUNDLE=com.zoharbabin.fen
cd "$(dirname "$0")/.."
FILE=$(grep -A12 "id: \"$MODEL\"" Shared/AI/ModelCatalog.swift | grep -o 'fileName: "[^"]*"' | head -1 | cut -d'"' -f2)
[ -n "$FILE" ] && [ -f "$FOLDER/$FILE" ] || { echo "no file for $MODEL in $FOLDER" >&2; exit 2; }
xcodegen generate > /dev/null
echo "== Build and install"
nice -n 10 xcodebuild build -project FenUITesting.xcodeproj -scheme FeniOSApp -destination "id=$DEVICE" \
    -allowProvisioningUpdates -derivedDataPath /tmp/fen-ios-device > /tmp/fen-models-ios.log 2>&1 || { tail -30 /tmp/fen-models-ios.log; exit 1; }
APP=$(ls -d /tmp/fen-ios-device/Build/Products/Debug-iphoneos/Fen.app)
xcrun devicectl device install app --device "$DEVICE" "$APP" > /dev/null
echo "== Copy $FILE"
xcrun devicectl device copy to --device "$DEVICE" --domain-type appDataContainer --domain-identifier $BUNDLE \
    --source "$FOLDER/$FILE" --destination "Library/.fen/models/$FILE" > /dev/null
echo "== Run"
xcrun devicectl device process launch --device "$DEVICE" --console --terminate-existing \
    --environment-variables "{\"FEN_MODEL_SELFTEST\": \"$MODEL\"}" $BUNDLE 2>&1 | grep SELFTEST || true
