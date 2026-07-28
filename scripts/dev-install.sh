#!/usr/bin/env bash
#
# dev-install.sh — build a debug .app, force-install it to /Applications, and
# relaunch it fresh, so what's running is provably the binary you just built.
#
#     ./scripts/dev-install.sh [file-to-open.md]
#
# Exists because of two false negatives that cost real debugging time:
#
#   1. A stale /Applications/Fen.app can silently outlive a source fix if you
#      forget to reinstall it — every "it's fixed" claim you make is actually
#      about old code. This script always rebuilds and reinstalls, never
#      reuses a previous .app.
#   2. `open -a Fen.app` on an app that's ALREADY RUNNING just foregrounds the
#      existing process — it does not reload the binary from disk. Replacing
#      the .app bundle while the old process is still running leaves you
#      looking at old code with a screenshot that "proves" the new build is
#      broken. This script kills any running instance by PID before
#      relaunching, so the process you see afterward is guaranteed fresh.
#
# Verify what's actually running, don't assume it from `open` succeeding:
#     ps aux | grep -i '/Applications/Fen.app/Contents/MacOS/Fen'
#
# For live DOM/JS inspection of the preview WKWebView (real state, not a
# screenshot), see docs/DEBUGGING.md — PreviewWebView.swift sets
# `webView.isInspectable = true` in #if DEBUG builds, which is exactly what
# this script produces.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="/Applications/Fen.app"
BIN_PATH_IN_APP="$APP_PATH/Contents/MacOS/Fen"

echo "==> Building debug .app..."
CONFIG=debug "$ROOT/scripts/build-app.sh" >/tmp/fen-dev-install-build.log 2>&1 || {
    echo "!! Build failed — see /tmp/fen-dev-install-build.log" >&2
    tail -40 /tmp/fen-dev-install-build.log >&2
    exit 1
}

echo "==> Killing any running Fen instance..."
OLD_PIDS="$(pgrep -f "$BIN_PATH_IN_APP" || true)"
if [ -n "$OLD_PIDS" ]; then
    echo "    killing PID(s): $OLD_PIDS"
    kill $OLD_PIDS
    # Wait for the old process to actually exit before replacing the bundle it's
    # running from -- a kill signal is asynchronous, not a guarantee it's gone yet.
    for _ in $(seq 1 50); do
        pgrep -f "$BIN_PATH_IN_APP" >/dev/null || break
        sleep 0.1
    done
fi

echo "==> Installing to ${APP_PATH}..."
rm -rf "$APP_PATH"
cp -R "$ROOT/dist/Fen.app" "$APP_PATH"

echo "==> Verifying the installed binary matches the fresh build..."
if ! diff -q "$ROOT/dist/Fen.app/Contents/MacOS/Fen" "$BIN_PATH_IN_APP" >/dev/null; then
    echo "!! Installed binary differs from the build output -- install failed." >&2
    exit 1
fi

echo "==> Launching fresh..."
if [ $# -gt 0 ]; then
    open -a "$APP_PATH" "$1"
else
    open -a "$APP_PATH"
fi

sleep 0.5
NEW_PID="$(pgrep -f "$BIN_PATH_IN_APP" || true)"
if [ -z "$NEW_PID" ]; then
    echo "!! No Fen process found after launch." >&2
    exit 1
fi
echo "==> Running as PID $NEW_PID: $(ps -p "$NEW_PID" -o comm=)"
echo "==> Done. Attach Safari's Develop menu to this window for live DOM inspection (see docs/DEBUGGING.md)."
