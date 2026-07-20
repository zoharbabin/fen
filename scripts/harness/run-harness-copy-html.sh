#!/bin/bash
# Regression gate for Copy as HTML / Copy as Rich Text (issue #33:
# https://github.com/zoharbabin/fen/issues/33). Runs every gate from that issue's
# harnessed-build spec (see issue #33's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-copy-html.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/copy-html-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

COPY_FILES=(
    Shared/Rendering/ClipboardExporter.swift
    macOS/CopyCommands.swift
)
COPY_TEST_FILES=(
    Tests/FenTests/ClipboardExporterIsolationTests.swift
    Tests/FenTests/ClipboardExporterSecurityTests.swift
    Tests/FenTests/ClipboardExporterTests.swift
    Tests/FenTests/ClipboardExporterE2ETest.swift
)

# --- Gate 1: Lint (project's existing linter/config) ---
log "Gate 1/6: swiftformat --lint + swiftlint"
swiftformat --lint . 2>&1 | tee "$RUN_DIR/01-swiftformat.log" || fail "swiftformat --lint found unformatted files"
swiftlint 2>&1 | tee "$RUN_DIR/01-swiftlint.log"
if grep -qE "error:" "$RUN_DIR/01-swiftlint.log"; then
    fail "swiftlint reported errors"
fi
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md; rule 2.3)"
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- copy is local, must not add network calls"
fi
log "Gate 1/6: no dynamic code execution introduced (rule 2.1)"
if grep -rn "Process(\|NSAppleScript\|eval(" "${COPY_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/01-dynexec-grep.log" | grep -q .; then
    fail "dynamic code execution API found in copy files"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (ClipboardExporterIsolationTests)"
if [ ! -f Tests/FenTests/ClipboardExporterIsolationTests.swift ]; then
    fail "ClipboardExporterIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter ClipboardExporterIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- two concurrent compositions cross-contaminated, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new copy feature files"
if grep -rnE "TODO|FIXME" "${COPY_FILES[@]}" "${COPY_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in copy feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (ClipboardExporterSecurityTests, ClipboardExporterTests)"
if [ ! -f Tests/FenTests/ClipboardExporterSecurityTests.swift ] || [ ! -f Tests/FenTests/ClipboardExporterTests.swift ]; then
    fail "ClipboardExporterSecurityTests.swift / ClipboardExporterTests.swift do not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter ClipboardExporterSecurityTests 2>&1 | tee "$RUN_DIR/05-ClipboardExporterSecurityTests.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ClipboardExporterSecurityTests failed, or no tests actually ran"
swift test --no-parallel --filter ClipboardExporterTests 2>&1 | tee "$RUN_DIR/05-ClipboardExporterTests.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ClipboardExporterTests failed, or no tests actually ran"

# --- Gate 6: E2E-style test of the real copy flow + full suite ---
log "Gate 6/6: E2E test (ClipboardExporterE2ETest) + full local test suite"
if [ ! -f Tests/FenTests/ClipboardExporterE2ETest.swift ]; then
    fail "ClipboardExporterE2ETest.swift does not exist yet -- nothing to run for gate 6"
fi
swift test --no-parallel --filter ClipboardExporterE2ETest 2>&1 | tee "$RUN_DIR/06-e2e.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ClipboardExporterE2ETest failed, or no tests actually ran"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
