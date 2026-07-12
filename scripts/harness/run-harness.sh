#!/bin/bash
# Regression gate for the document-outline / TOC-navigator feature (issue #12:
# https://github.com/zoharbabin/fen/issues/12). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/outline-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
    fail "URLSession usage found -- outline feature must not introduce network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance isolation test ---
log "Gate 3/6: multi-instance isolation test (DocumentOutlineIsolationTests)"
swift test --no-parallel --filter DocumentOutlineIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- outline state leaked across instances"

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no TODO/FIXME/stub markers in new outline files"
if grep -rnE "TODO|FIXME" \
    Shared/Navigation Tests/FenTests/DocumentOutline*.swift UITests/FenUITests/DocumentOutlineUITests.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in outline feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit/integration tests (DocumentOutlineTests, DocumentOutlineSecurityTests)"
swift test --no-parallel --filter DocumentOutlineTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "DocumentOutlineTests failed"
swift test --no-parallel --filter DocumentOutlineSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "DocumentOutlineSecurityTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (DocumentOutlineUITests) -- screenshots attached to test result"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/DocumentOutlineUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "DocumentOutlineUITests E2E run failed"

log "All 6 gates passed. Run log: $RUN_DIR"
