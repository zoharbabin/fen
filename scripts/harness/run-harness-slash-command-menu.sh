#!/bin/bash
# Regression gate for the slash-command menu for block insertion (issue #1:
# https://github.com/zoharbabin/fen/issues/1). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-slash-command-menu.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/slash-command-menu-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md, rule 2.3)"
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- the slash-command menu must not introduce network calls"
fi
log "Gate 1/6: no dynamic code execution in the new slash-menu files (rule 2.1)"
SLASH_MENU_SOURCE_FILES=(
    Shared/Editor/SlashCommandMenu.swift
    Shared/Views/SlashCommandMenuView.swift
)
if grep -rnE "\beval\b|\bexec\b|evaluateJavaScript" "${SLASH_MENU_SOURCE_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/01-eval-grep.log" | grep -q .; then
    fail "eval/exec/evaluateJavaScript found in slash-menu files -- rule 2.1 requires plain string/NSRange logic only"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation test ---
log "Gate 3/6: isolation test (SlashCommandMenuIsolationTests)"
swift test --no-parallel --filter SlashCommandMenuIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- slash-menu state leaked across Coordinator instances"
assert_tests_ran "$RUN_DIR/03-isolation.log" "SlashCommandMenuIsolationTests" "Test run with 0 tests"

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new slash-menu files"
SLASH_MENU_FILES=(
    Shared/Editor/SlashCommandMenu.swift
    Shared/Views/SlashCommandMenuView.swift
    Tests/FenTests/SlashCommandMenuTests.swift
    Tests/FenTests/SlashCommandMenuIsolationTests.swift
    Tests/FenTests/SlashCommandMenuSecurityTests.swift
    UITests/FenUITests/SlashCommandMenuUITests.swift
)
for f in "${SLASH_MENU_FILES[@]}"; do
    [ -f "$f" ] || fail "expected slash-menu file missing: $f"
done
if grep -rnE "TODO|FIXME" "${SLASH_MENU_FILES[@]}" | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in slash-menu feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/security tests (SlashCommandMenuTests, SlashCommandMenuSecurityTests, MarkdownFormattingTests)"
swift test --no-parallel --filter SlashCommandMenuTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "SlashCommandMenuTests failed"
assert_tests_ran "$RUN_DIR/05-unit.log" "SlashCommandMenuTests" "Test run with 0 tests"
swift test --no-parallel --filter SlashCommandMenuSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "SlashCommandMenuSecurityTests failed"
assert_tests_ran "$RUN_DIR/05-security.log" "SlashCommandMenuSecurityTests" "Test run with 0 tests"
swift test --no-parallel --filter MarkdownFormattingTests 2>&1 | tee "$RUN_DIR/05-formatting.log" \
    || fail "MarkdownFormattingTests failed (extended for .mermaidDiagram and the rule 3.6 table cursor decision)"
assert_tests_ran "$RUN_DIR/05-formatting.log" "MarkdownFormattingTests" "Test run with 0 tests"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (SlashCommandMenuUITests) -- screenshots attached to test result"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/SlashCommandMenuUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "SlashCommandMenuUITests E2E run failed"
assert_tests_ran "$RUN_DIR/06-e2e.log" "SlashCommandMenuUITests"

log "All 6 gates passed. Run log: $RUN_DIR"
