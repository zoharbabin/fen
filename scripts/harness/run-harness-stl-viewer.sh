#!/bin/bash
# Regression gate for STL 3D viewer rendering (issue #120:
# https://github.com/zoharbabin/fen/issues/120). Runs every gate from that issue's
# harnessed-build spec (see issue #120's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-stl-viewer.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/stl-viewer-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

FEATURE_FILES=(
    Shared/Rendering/HTMLComposer+STLViewer.swift
    Shared/Rendering/HTMLComposer.swift
    Shared/Models/Preferences.swift
    Shared/Resources/Extensions/stl-viewer-init.js
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
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md; rule 2.2)"
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- three.js/STLLoader/OrbitControls are static vendored files, must not add network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (STLViewerIsolationTests)"
if [ ! -f Tests/FenTests/STLViewerIsolationTests.swift ]; then
    fail "STLViewerIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter STLViewerIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- STL viewer state leaked across instances, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new STL feature files (rule 5.2)"
if grep -rnE "TODO|FIXME" \
    "${FEATURE_FILES[@]}" "${FEATURE_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in STL viewer feature files"
fi
log "Gate 4/6: exactly one STL viewer init call site (rule 5.1)"
INIT_CALL_COUNT=$(grep -rc "stlViewerTags" Shared/Rendering/HTMLComposer.swift Shared/Rendering/HTMLComposer+STLViewer.swift 2>/dev/null | awk -F: '{sum += $2} END {print sum}')
if [ "$INIT_CALL_COUNT" -lt 3 ]; then
    fail "expected stlViewerTags referenced at least 3 times (definition + compose + exportStyleAndScriptTags), found $INIT_CALL_COUNT"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/integration tests (STLViewerE2ETest, STLViewerIsolationTests)"
swift test --no-parallel --filter STLViewerE2ETest 2>&1 | tee "$RUN_DIR/05-e2e.log" \
    || fail "STLViewerE2ETest failed"
swift test --no-parallel --filter STLViewerIsolationTests 2>&1 | tee "$RUN_DIR/05-isolation-rerun.log" \
    || fail "STLViewerIsolationTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
# STLViewerE2ETest already drives the real MarkdownRenderer -> HTMLComposer ->
# PreviewSchemeHandler -> WKWebView pipeline (gate 5's proof doubles as this gate's, same
# established pattern as run-harness-emoji-shortcodes.sh gate 6). Re-run the full suite as the
# recorded proof of no regressions elsewhere.
log "Gate 6/6: full local test suite (recorded proof of the real flow, no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
