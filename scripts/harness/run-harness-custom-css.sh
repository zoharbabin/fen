#!/bin/bash
# Regression gate for preview style picker polish + custom CSS support (issue #26:
# https://github.com/zoharbabin/fen/issues/26). Runs every gate from that issue's
# harnessed-build spec (see issue #26's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-custom-css.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/custom-css-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
log "Gate 3/6: isolation test (CustomCSSIsolationTests)"
if [ ! -f Tests/FenTests/CustomCSSIsolationTests.swift ]; then
    fail "CustomCSSIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter CustomCSSIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- one Preferences instance's custom CSS state leaked into another's"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new/touched custom-CSS feature files"
if grep -rnE "TODO|FIXME" \
    Shared/Rendering/HTMLComposer.swift Shared/Models/Preferences.swift Shared/Views/SettingsView.swift \
    Tests/FenTests/CustomCSSIsolationTests.swift Tests/FenTests/CustomCSSSanitizationVerifyTest.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in custom-CSS feature files"
fi

# --- Gate 5: Unit tests proving each Phase-1 rule (rules 2.1, 2.2, 3.1, 3.2, 3.3) ---
log "Gate 5/6: unit tests (CustomCSSSanitizationVerifyTest -- sanitization/fallback cases)"
if [ ! -f Tests/FenTests/CustomCSSSanitizationVerifyTest.swift ]; then
    fail "CustomCSSSanitizationVerifyTest.swift does not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter CustomCSSSanitizationVerifyTest 2>&1 | tee "$RUN_DIR/05-verify.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "CustomCSSSanitizationVerifyTest failed, or no tests actually ran"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E test (real WKWebView render through HTMLComposer.compose)"
swift test --no-parallel --filter PreviewThemeCoverageTests 2>&1 | tee "$RUN_DIR/06-e2e-theme-coverage.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "PreviewThemeCoverageTests regressed -- theme rendering broke under the new custom-CSS injection point"
log "Gate 6/6: full local test suite (no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
