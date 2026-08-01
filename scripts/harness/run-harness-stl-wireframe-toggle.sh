#!/bin/bash
# Regression gate for the STL viewer's per-viewer wireframe toggle (issue #122:
# https://github.com/zoharbabin/fen/issues/122). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-stl-wireframe-toggle.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/stl-wireframe-toggle-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

FEATURE_FILES=(
    Shared/Resources/Extensions/stl-viewer-init.js
    Shared/Resources/Extensions/stl-viewer.css
)
FEATURE_TEST_FILES=(
    Tests/FenTests/STLViewerIsolationTests.swift
    Tests/FenTests/STLViewerE2ETest.swift
)

# --- Gate 1: Lint (project's existing linter/config) ---
log "Gate 1/6: swiftformat --lint + swiftlint"
swiftformat --lint . 2>&1 | tee "$RUN_DIR/01-swiftformat.log" || fail "swiftformat --lint found unformatted files"
swiftlint 2>&1 | tee "$RUN_DIR/01-swiftlint.log"
if grep -qE "error:" "$RUN_DIR/01-swiftlint.log"; then
    fail "swiftlint reported errors"
fi
log "Gate 1/6: no inline event handlers on the toggle button (rule 2.1)"
if grep -n "onclick=" "${FEATURE_FILES[@]}" 2>/dev/null | tee "$RUN_DIR/01-onclick-grep.log" | grep -q .; then
    fail "inline onclick= attribute found -- must be wired via addEventListener"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (STLViewerIsolationTests, incl. wireframe toggle isolation)"
if ! swift test --no-parallel --filter STLViewerIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- wireframe toggle state leaked across viewers, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in wireframe toggle feature files (rule 5.1)"
if grep -rnE "TODO|FIXME" \
    "${FEATURE_FILES[@]}" "${FEATURE_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in wireframe toggle feature files"
fi
log "Gate 4/6: exactly one wireframe-toggle button creation site (rule 5.1)"
CREATE_SITE_COUNT=$(grep -c "function makeWireframeToggle" Shared/Resources/Extensions/stl-viewer-init.js 2>/dev/null || echo 0)
if [ "$CREATE_SITE_COUNT" -ne 1 ]; then
    fail "expected exactly one makeWireframeToggle definition, found $CREATE_SITE_COUNT"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/integration tests (STLViewerE2ETest, STLViewerIsolationTests)"
swift test --no-parallel --filter STLViewerE2ETest 2>&1 | tee "$RUN_DIR/05-e2e.log" \
    || fail "STLViewerE2ETest failed"
swift test --no-parallel --filter STLViewerIsolationTests 2>&1 | tee "$RUN_DIR/05-isolation-rerun.log" \
    || fail "STLViewerIsolationTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
# STLViewerE2ETest already drives the real MarkdownRenderer -> HTMLComposer ->
# PreviewSchemeHandler -> WKWebView pipeline including the new wireframe-toggle tests (gate 5's
# proof doubles as this gate's, same established pattern as run-harness-stl-viewer.sh gate 6).
# Re-run the full suite as the recorded proof of no regressions elsewhere.
log "Gate 6/6: full local test suite (recorded proof of the real flow, no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
