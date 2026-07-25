#!/bin/bash
# Regression gate for the live-preview (WYSIWYG-in-source) editing mode feature
# (issue #2: https://github.com/zoharbabin/fen/issues/2). Runs every gate from
# that issue's harnessed-build spec in order and fails loud on the first
# non-zero exit.
#
# Usage: scripts/harness/run-harness-live-preview.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/live-preview-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- live preview must not introduce network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation test ---
log "Gate 3/6: isolation test (LivePreviewIsolationTests)"
swift test --no-parallel --filter LivePreviewIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- live-preview state leaked across Coordinator instances"
assert_tests_ran "$RUN_DIR/03-isolation.log" "LivePreviewIsolationTests" "Test run with 0 tests"

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new live-preview files"
LIVE_PREVIEW_FILES=(
    Shared/Editor/MarkdownTextView+LivePreview.swift
    Shared/Editor/MarkdownTextView+LivePreview_iOS.swift
    Tests/FenTests/LivePreviewTests.swift
    Tests/FenTests/LivePreviewIsolationTests.swift
    Tests/FenTests/LivePreviewSecurityTests.swift
    UITests/FenUITests/LivePreviewUITests.swift
)
for f in "${LIVE_PREVIEW_FILES[@]}"; do
    [ -f "$f" ] || fail "expected live-preview file missing: $f"
done
if grep -rnE "TODO|FIXME" "${LIVE_PREVIEW_FILES[@]}" | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in live-preview feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/security tests (LivePreviewTests, LivePreviewSecurityTests, PreferencesTests)"
swift test --no-parallel --filter LivePreviewTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "LivePreviewTests failed"
assert_tests_ran "$RUN_DIR/05-unit.log" "LivePreviewTests" "Test run with 0 tests"
swift test --no-parallel --filter LivePreviewSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "LivePreviewSecurityTests failed"
assert_tests_ran "$RUN_DIR/05-security.log" "LivePreviewSecurityTests" "Test run with 0 tests"
swift test --no-parallel --filter PreferencesTests 2>&1 | tee "$RUN_DIR/05-preferences.log" \
    || fail "PreferencesTests failed (extended for editorLivePreviewEnabled, rule 1.2)"
assert_tests_ran "$RUN_DIR/05-preferences.log" "PreferencesTests" "Test run with 0 tests"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (LivePreviewUITests) -- screenshots attached to test result"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/LivePreviewUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "LivePreviewUITests E2E run failed"
assert_tests_ran "$RUN_DIR/06-e2e.log" "LivePreviewUITests"

log "All 6 gates passed. Run log: $RUN_DIR"
