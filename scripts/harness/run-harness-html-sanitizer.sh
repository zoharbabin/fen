#!/bin/bash
# Regression gate for the raw-HTML sanitizer (issue #118:
# https://github.com/zoharbabin/fen/issues/118). Runs every gate from that issue's
# harnessed-build spec (see issue #118's Phase 1 comments) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-html-sanitizer.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/html-sanitizer-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

FEATURE_FILES=(
    Shared/Preview/HTMLSanitizer.swift
    Shared/Resources/Extensions/sanitize-config.js
    Shared/Rendering/MarkdownRenderer.swift
    Shared/Models/Preferences.swift
    Shared/Views/SplitEditorView.swift
)
FEATURE_TEST_FILES=(
    Tests/FenTests/SanitizerIsolationTests.swift
    Tests/FenTests/SanitizerSecurityTests.swift
    Tests/FenTests/SanitizerFailClosedTests.swift
    Tests/FenTests/SanitizerLazyLoadVerifyTest.swift
    Tests/FenTests/SanitizerRenderOrderingTests.swift
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
    fail "URLSession usage found -- DOMPurify is a static vendored file, must not add network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (SanitizerIsolationTests)"
if [ ! -f Tests/FenTests/SanitizerIsolationTests.swift ]; then
    fail "SanitizerIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter SanitizerIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- sanitizer state leaked across instances, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new sanitizer feature files (rule 5.2)"
if grep -rnE "TODO|FIXME" \
    "${FEATURE_FILES[@]}" "${FEATURE_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in sanitizer feature files"
fi
log "Gate 4/6: exactly one DOMPurify.sanitize call site (rule 5.1)"
CALL_SITE_COUNT=$(grep -rc "DOMPurify.sanitize" Shared/Resources/Extensions/sanitize-config.js 2>/dev/null | awk -F: '{sum += $2} END {print sum}')
if [ "$CALL_SITE_COUNT" -ne 1 ]; then
    fail "expected exactly one DOMPurify.sanitize call site, found $CALL_SITE_COUNT"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/integration tests (all Sanitizer* suites)"
swift test --no-parallel --filter SanitizerSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "SanitizerSecurityTests failed"
swift test --no-parallel --filter SanitizerFailClosedTests 2>&1 | tee "$RUN_DIR/05-fail-closed.log" \
    || fail "SanitizerFailClosedTests failed"
swift test --no-parallel --filter SanitizerLazyLoadVerifyTest 2>&1 | tee "$RUN_DIR/05-lazy-load.log" \
    || fail "SanitizerLazyLoadVerifyTest failed"
swift test --no-parallel --filter SanitizerRenderOrderingTests 2>&1 | tee "$RUN_DIR/05-render-ordering.log" \
    || fail "SanitizerRenderOrderingTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
# SanitizerSecurityTests already drives the real MarkdownRenderer -> HTMLSanitizer ->
# HTMLComposer pipeline end to end (rule 2.1's proof), same established pattern as
# run-harness-emoji-shortcodes.sh gate 6. Re-run the full suite as the recorded proof of no
# regressions elsewhere -- this also re-proves rule 2.3 (PreviewSchemeHandler's path guard is
# untouched), since PreviewSchemeHandlerVerifyTest/PreviewSchemeHandlerSecurityTests run within it.
log "Gate 6/6: full local test suite (recorded proof of the real flow, no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
