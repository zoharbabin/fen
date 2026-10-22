#!/bin/bash
# Runs one model on this Mac and prints load time, first text, total time, peak memory and heat
# (issue #253). The Mac twin of test-models-device.sh. It builds a debug Fen, clones the model file
# into ~/.fen/models and launches the app with FEN_MODEL_SELFTEST=<model id>. The app prints the lines
# that start with SELFTEST (`DeviceSelfTest`) and deletes the copy when the run ends. No UI is driven.
#
#   scripts/test-models-mac.sh apple-system                       # the OS model, no file needed
#   scripts/test-models-mac.sh <model id> <folder with the .gguf files>
set -euo pipefail
[ $# -ge 1 ] || { echo "usage: $0 apple-system | <model id> <model folder>" >&2; exit 2; }
MODEL=$1; FOLDER=${2:-}
cd "$(dirname "$0")/.."
COPY=""
if [ "$MODEL" != "apple-system" ]; then
    [ -n "$FOLDER" ] || { echo "a model id needs a folder" >&2; exit 2; }
    FILE=$(grep -A12 "id: \"$MODEL\"" Shared/AI/ModelCatalog.swift | grep -o 'fileName: "[^"]*"' | head -1 | cut -d'"' -f2)
    [ -n "$FILE" ] && [ -f "$FOLDER/$FILE" ] || { echo "no file for $MODEL in $FOLDER" >&2; exit 2; }
    COPY="$HOME/.fen/models/$FILE"
    # The app deletes the copy when it finishes, so never run over a model you downloaded in Settings.
    [ ! -e "$COPY" ] || { echo "$COPY already exists. Remove it first." >&2; exit 2; }
fi
xcodegen generate > /dev/null
echo "== Build"
nice -n 10 xcodebuild build -project FenUITesting.xcodeproj -scheme FenMacOSApp -destination 'platform=macOS' \
    -derivedDataPath /tmp/fen-mac-selftest > /tmp/fen-models-mac.log 2>&1 || { tail -30 /tmp/fen-models-mac.log; exit 1; }
APP=/tmp/fen-mac-selftest/Build/Products/Debug/Fen.app
if [ -n "$COPY" ]; then
    echo "== Clone $FILE"
    mkdir -p "$HOME/.fen/models"
    trap 'rm -f "$COPY"' EXIT
    cp -c "$FOLDER/$FILE" "$COPY"
fi
echo "== Run"
FEN_MODEL_SELFTEST="$MODEL" "$APP/Contents/MacOS/Fen" 2>&1 | grep SELFTEST || true
