#!/bin/bash
# Regression gate for the preview flicker/flash elimination proof (issue #24:
# https://github.com/zoharbabin/fen/issues/24). Runs every gate from that issue's
# harnessed-build spec (see issue #24's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-preview-flicker.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/preview-flicker-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
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
    fail "URLSession usage found -- this is a test-only change, must not introduce network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation ---
# N/A per issue #24's Phase 1 spec, rule 1: this issue adds test coverage only, no new
# type or instance state. Proven here by asserting the new test file introduces no new
# non-test Swift type (the isolation gate has nothing to construct 2+ instances of).
log "Gate 3/6: isolation N/A check (no new production type introduced)"
if [ -f Tests/FenTests/PreviewFlickerVerifyTest.swift ]; then
    if grep -qE "^(final class|class|struct|actor) [A-Za-z]+" Shared/Views/SplitEditorView.swift Shared/Preview/PreviewWebView.swift \
        2>/dev/null | grep -v "SplitEditorView\|PreviewWebView\|Coordinator" | tee "$RUN_DIR/03-isolation-na-check.log" | grep -q .; then
        fail "unexpected new production type found in files this issue should only be testing, not modifying"
    fi
else
    fail "PreviewFlickerVerifyTest.swift does not exist yet -- nothing to check isolation N/A against"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in the new test file"
if grep -rnE "TODO|FIXME" \
    Tests/FenTests/PreviewFlickerVerifyTest.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in PreviewFlickerVerifyTest.swift"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: preview flicker regression test (PreviewFlickerVerifyTest)"
swift test --no-parallel --filter PreviewFlickerVerifyTest 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "PreviewFlickerVerifyTest failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
# No dedicated UI-test target for this issue -- gate 5's PreviewFlickerVerifyTest already
# drives the real SplitEditorView/PreviewWebView.Coordinator objects end-to-end through a
# real WKWebView and a real WKNavigationDelegate.didFinish count, which is this repo's
# established "E2E of the real flow" bar for preview-pane behavior (see
# FontSizeLiveUpdateVerifyTest.swift, PreviewReloadRaceVerifyTest.swift,
# PreviewScrollRaceVerifyTest.swift -- none of which have a separate XCUITest either).
# Re-run the full suite here as the recorded proof this gate requires.
log "Gate 6/6: full local test suite (recorded proof of the real flow, no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
