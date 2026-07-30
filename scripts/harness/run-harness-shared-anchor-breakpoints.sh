#!/bin/bash
# Regression gate for the shared editor/preview anchor-breakpoint fix (issue #113:
# https://github.com/zoharbabin/fen/issues/113). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-shared-anchor-breakpoints.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/shared-anchor-breakpoints-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
    fail "URLSession usage found -- the anchor-breakpoint fix must not introduce network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation test ---
log "Gate 3/6: isolation test (EditorGutterIsolationTests -- covers the anchor-table Coordinator state this fix touches)"
swift test --no-parallel --filter EditorGutterIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- anchor state leaked across Coordinator/WKWebView instances"
assert_tests_ran "$RUN_DIR/03-isolation.log" "EditorGutterIsolationTests" "Test run with 0 tests"

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in touched anchor-breakpoint files"
ANCHOR_BREAKPOINT_FILES=(
    Shared/Rendering/MarkdownRenderer.swift
    Shared/Editor/EditorScrollAnchors.swift
    Shared/Editor/MarkdownTextView.swift
    Shared/Editor/MarkdownTextView_iOS.swift
    Shared/Views/SplitEditorView.swift
    Tests/FenTests/EditorScrollAnchorTests.swift
    Tests/FenTests/EditorPreviewGutterAgreementTest.swift
    Tests/FenTests/MarkdownRendererTests.swift
)
for f in "${ANCHOR_BREAKPOINT_FILES[@]}"; do
    [ -f "$f" ] || fail "expected anchor-breakpoint file missing: $f"
done
if grep -rnE "TODO|FIXME" "${ANCHOR_BREAKPOINT_FILES[@]}" | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in anchor-breakpoint feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (EditorScrollAnchorTests, MarkdownRendererTests, EditorPreviewGutterAgreementTest, CrossLanguageInterpolationTest, ScrollSyncVerifyTest)"
swift test --no-parallel --filter EditorScrollAnchorTests 2>&1 | tee "$RUN_DIR/05-anchors.log" \
    || fail "EditorScrollAnchorTests failed"
assert_tests_ran "$RUN_DIR/05-anchors.log" "EditorScrollAnchorTests" "Test run with 0 tests"
swift test --no-parallel --filter MarkdownRendererTests 2>&1 | tee "$RUN_DIR/05-renderer.log" \
    || fail "MarkdownRendererTests failed"
assert_tests_ran "$RUN_DIR/05-renderer.log" "MarkdownRendererTests" "Test run with 0 tests"
swift test --no-parallel --filter EditorPreviewGutterAgreementTest 2>&1 | tee "$RUN_DIR/05-agreement.log" \
    || fail "EditorPreviewGutterAgreementTest failed"
assert_tests_ran "$RUN_DIR/05-agreement.log" "EditorPreviewGutterAgreementTest" "Test run with 0 tests"
swift test --no-parallel --filter CrossLanguageInterpolationTest 2>&1 | tee "$RUN_DIR/05-crosslang.log" \
    || fail "CrossLanguageInterpolationTest failed"
assert_tests_ran "$RUN_DIR/05-crosslang.log" "CrossLanguageInterpolationTest" "Test run with 0 tests"
swift test --no-parallel --filter ScrollSyncVerifyTest 2>&1 | tee "$RUN_DIR/05-scrollsync.log" \
    || fail "ScrollSyncVerifyTest failed"
assert_tests_ran "$RUN_DIR/05-scrollsync.log" "ScrollSyncVerifyTest" "Test run with 0 tests"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (ScrollSyncUITests) -- exercises real documents in a real built app"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/ScrollSyncUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "ScrollSyncUITests E2E run failed"
assert_tests_ran "$RUN_DIR/06-e2e.log" "ScrollSyncUITests"

log "All 6 gates passed. Run log: $RUN_DIR"
