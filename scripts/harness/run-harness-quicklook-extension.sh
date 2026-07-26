#!/bin/bash
# Regression gate for the Quick Look preview extension for .md files (issue #49:
# https://github.com/zoharbabin/fen/issues/49). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-quicklook-extension.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/quicklook-extension-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

# See run-harness-focus-mode.sh's doc comment: `swift test`'s Swift Testing summary line is
# what actually reflects whether a --filter matched anything; xcodebuild's legacy XCTest
# wrapper uses a different string.
assert_tests_ran() {
    local logfile=$1 label=$2 pattern=${3:-"Executed 0 tests"}
    if grep -qE "$pattern" "$logfile"; then
        fail "$label matched zero tests -- the referenced test suite/file doesn't exist or is empty"
    fi
}

# --- Gate 1: Lint (project's existing linter/config) ---
log "Gate 1/6: swiftformat --lint + swiftlint"
swiftformat --lint . 2>&1 | tee "$RUN_DIR/01-swiftformat.log" || fail "swiftformat --lint found unformatted files"
swiftlint 2>&1 | tee "$RUN_DIR/01-swiftlint.log"
if grep -qE "error:" "$RUN_DIR/01-swiftlint.log"; then
    fail "swiftlint reported errors"
fi
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md)"
if grep -rn "URLSession" Shared macOS iOS FenQuickLook 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- the Quick Look extension must not introduce network calls"
fi
log "Gate 1/6: entitlements stay minimal (rule 2.1 -- sandbox + read-only file access + network client only)"
# com.apple.security.network.client is required for WKWebView's Networking/WebContent XPC
# helpers to launch inside a sandboxed process at all -- confirmed by reproduction: without it,
# quicklookd's `qlmanage -p` invocation renders a blank preview because those helper processes
# crash before ever reaching PreviewViewController's HTML render step. It grants no actual
# outbound network access QuickLookPreviewRenderer would use -- see Gate 1's URLSession check
# below, which still fails loud on any real network call.
if [ -f FenQuickLook/FenQuickLook.entitlements ]; then
    /usr/libexec/PlistBuddy -c "Print" FenQuickLook/FenQuickLook.entitlements > "$RUN_DIR/01-entitlements.log"
    if grep -qE "com\.apple\.security\.network\.server|com\.apple\.security\.cs\.allow-jit" "$RUN_DIR/01-entitlements.log"; then
        fail "FenQuickLook.entitlements grants a broader entitlement than sandbox + read-only file access + network client"
    fi
    if ! grep -q "com.apple.security.network.client" "$RUN_DIR/01-entitlements.log"; then
        fail "FenQuickLook.entitlements is missing com.apple.security.network.client -- required for WKWebView to render at all inside the sandboxed extension"
    fi
else
    fail "FenQuickLook/FenQuickLook.entitlements does not exist yet"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS FenQuickLook 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance/process isolation test ---
log "Gate 3/6: isolation test (QuickLookIsolationTests)"
swift test --no-parallel --filter QuickLookIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- render state leaked across HTMLComposer/Preferences instances"
assert_tests_ran "$RUN_DIR/03-isolation.log" "QuickLookIsolationTests" "Test run with 0 tests"

# --- Gate 4: Dead-code scan + fixed set of expected files + real extension bundle ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new Quick Look extension files"
QUICKLOOK_FILES=(
    FenQuickLook/PreviewViewController.swift
    FenQuickLook/Info.plist
    FenQuickLook/FenQuickLook.entitlements
    Tests/FenTests/QuickLookIsolationTests.swift
    Tests/FenTests/QuickLookTests.swift
    Tests/FenTests/QuickLookSecurityTests.swift
)
for f in "${QUICKLOOK_FILES[@]}"; do
    [ -f "$f" ] || fail "expected Quick Look extension file missing: $f"
done
if grep -rnE "TODO|FIXME" "${QUICKLOOK_FILES[@]}" | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in Quick Look extension feature files"
fi
log "Gate 4/6: extension target builds and embeds into the real app bundle"
xcodegen generate 2>&1 | tee "$RUN_DIR/04-xcodegen.log"
xcodebuild build \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    2>&1 | tee "$RUN_DIR/04-xcodebuild.log" \
    || fail "FenMacOSApp build failed with the FenQuickLook extension target added"
BUILT_APP="$(find ~/Library/Developer/Xcode/DerivedData -maxdepth 1 -iname "FenUITesting-*" -type d 2>/dev/null \
    -exec stat -f "%m %N" {} \; | sort -rn | head -1 | cut -d' ' -f2-)/Build/Products/Debug/Fen.app"
if [ ! -d "$BUILT_APP/Contents/PlugIns/FenQuickLook.appex" ]; then
    fail "FenQuickLook.appex is not embedded in the built Fen.app bundle"
fi

# --- Gate 5: Unit/integration/security tests proving each Phase-1 rule ---
log "Gate 5/6: unit/security tests (QuickLookTests, QuickLookSecurityTests)"
swift test --no-parallel --filter QuickLookTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "QuickLookTests failed"
assert_tests_ran "$RUN_DIR/05-unit.log" "QuickLookTests" "Test run with 0 tests"
swift test --no-parallel --filter QuickLookSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "QuickLookSecurityTests failed"
assert_tests_ran "$RUN_DIR/05-security.log" "QuickLookSecurityTests" "Test run with 0 tests"

# --- Gate 6: E2E proof ---
# QLPreviewingController extensions are invoked by Finder/qlmanage, not by xcodebuild test --
# no XCUITest API drives a real Quick Look popup. Gate 6 is therefore a manual step: run
# `qlmanage -p <file>.md` against the built app and attach the resulting screenshot to the
# closing PR/comment, per this issue's own stated proof requirement. This script cannot
# automate that step, but it fails loud here as a reminder that it has not yet been done.
log "Gate 6/6: manual QuickLook proof (qlmanage -p) -- NOT automatable, see comment above"
if [ ! -f "$RUN_DIR/../quicklook-manual-proof.png" ] && [ ! -f ".harness-runs/quicklook-manual-proof.png" ]; then
    fail "manual QuickLook screenshot proof not found at .harness-runs/quicklook-manual-proof.png -- run 'qlmanage -p <file>.md' against the built app and save a screenshot there before closing the issue"
fi

log "All 6 gates passed. Run log: $RUN_DIR"
