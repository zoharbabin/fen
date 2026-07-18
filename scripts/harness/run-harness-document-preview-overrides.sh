#!/bin/bash
# Regression gate for per-document front-matter driven preview options (issue #27:
# https://github.com/zoharbabin/fen/issues/27). Runs every gate from that issue's
# harnessed-build spec (see issue #27's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-document-preview-overrides.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/document-preview-overrides-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (DocumentPreviewOverridesIsolationTests)"
if [ ! -f Tests/FenTests/DocumentPreviewOverridesIsolationTests.swift ]; then
    fail "DocumentPreviewOverridesIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter DocumentPreviewOverridesIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- one document's front-matter override leaked into another's"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new/touched document-preview-overrides feature files"
if grep -rnE "TODO|FIXME" \
    Shared/Models/DocumentPreviewOverrides.swift Shared/Rendering/HTMLComposer.swift \
    Shared/Rendering/MarkdownRenderer.swift Shared/Views/SplitEditorView.swift \
    Tests/FenTests/DocumentPreviewOverridesIsolationTests.swift \
    Tests/FenTests/DocumentPreviewOverridesVerifyTest.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in document-preview-overrides feature files"
fi

# --- Gate 5: Unit tests proving each Phase-1 rule (rules 2.1, 3.1, 3.2, 3.3) ---
log "Gate 5/6: unit tests (DocumentPreviewOverridesVerifyTest -- parsing/fallback cases)"
if [ ! -f Tests/FenTests/DocumentPreviewOverridesVerifyTest.swift ]; then
    fail "DocumentPreviewOverridesVerifyTest.swift does not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter DocumentPreviewOverridesVerifyTest 2>&1 | tee "$RUN_DIR/05-verify.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "DocumentPreviewOverridesVerifyTest failed, or no tests actually ran"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E test (real WKWebView render through HTMLComposer.compose with document overrides)"
swift test --no-parallel --filter PreviewThemeCoverageTests 2>&1 | tee "$RUN_DIR/06-e2e-theme-coverage.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "PreviewThemeCoverageTests regressed -- theme rendering broke under the new override parameter"
log "Gate 6/6: full local test suite (no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
