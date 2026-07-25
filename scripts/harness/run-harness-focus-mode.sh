#!/bin/bash
# Regression gate for the focus/typewriter mode feature (issue #19:
# https://github.com/zoharbabin/fen/issues/19). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-focus-mode.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/focus-mode-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

# swift test/xcodebuild test both exit 0 when a --filter/-only-testing name matches zero
# tests (e.g. the test file doesn't exist yet) -- so a green run log is not proof anything
# was actually exercised. Fail loud on that vacuous-pass case instead of trusting the exit code.
#
# `swift test` always runs an empty legacy `FenPackageTests.xctest` wrapper suite ahead of the
# real Swift Testing run, which unconditionally logs its own "Executed 0 tests" line -- so that
# exact string is a false positive for every `swift test --filter` invocation, matched or not.
# Swift Testing's own summary line ("Test run with N tests in M suites") is what actually
# reflects whether the requested filter matched anything, so gates 3 and 5 (swift test) check
# that instead; gate 6 (xcodebuild, plain XCTest, no such wrapper) keeps the legacy check.
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
    fail "URLSession usage found -- focus mode must not introduce network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation test ---
log "Gate 3/6: isolation test (FocusModeIsolationTests)"
swift test --no-parallel --filter FocusModeIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- focus-mode state leaked across Coordinator instances"
assert_tests_ran "$RUN_DIR/03-isolation.log" "FocusModeIsolationTests" "Test run with 0 tests"

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new focus-mode files"
FOCUS_MODE_FILES=(
    Shared/Editor/FocusModeEditing.swift
    Tests/FenTests/FocusModeTests.swift
    Tests/FenTests/FocusModeIsolationTests.swift
    Tests/FenTests/FocusModeSecurityTests.swift
    UITests/FenUITests/FocusModeUITests.swift
)
for f in "${FOCUS_MODE_FILES[@]}"; do
    [ -f "$f" ] || fail "expected focus-mode file missing: $f"
done
if grep -rnE "TODO|FIXME" "${FOCUS_MODE_FILES[@]}" | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in focus-mode feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/security tests (FocusModeTests, FocusModeSecurityTests, PreferencesTests)"
swift test --no-parallel --filter FocusModeTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "FocusModeTests failed"
assert_tests_ran "$RUN_DIR/05-unit.log" "FocusModeTests" "Test run with 0 tests"
swift test --no-parallel --filter FocusModeSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "FocusModeSecurityTests failed"
assert_tests_ran "$RUN_DIR/05-security.log" "FocusModeSecurityTests" "Test run with 0 tests"
swift test --no-parallel --filter PreferencesTests 2>&1 | tee "$RUN_DIR/05-preferences.log" \
    || fail "PreferencesTests failed (extended for editorFocusModeEnabled, rule 1.3)"
assert_tests_ran "$RUN_DIR/05-preferences.log" "PreferencesTests" "Test run with 0 tests"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (FocusModeUITests) -- screenshots attached to test result"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/FocusModeUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "FocusModeUITests E2E run failed"
assert_tests_ran "$RUN_DIR/06-e2e.log" "FocusModeUITests"

log "All 6 gates passed. Run log: $RUN_DIR"
