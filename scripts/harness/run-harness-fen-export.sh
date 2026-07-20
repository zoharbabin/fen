#!/bin/bash
# Regression gate for the `fen-export` CLI command (issue #34:
# https://github.com/zoharbabin/fen/issues/34). Runs every gate from that issue's
# harnessed-build spec (see issue #34's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-fen-export.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/fen-export-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

CLI_FILES=(
    Shared/CLI/ExportCLIRunner.swift
    CLI/FenExportCLI/main.swift
)
CLI_TEST_FILES=(
    Tests/FenTests/CLIRunnerIsolationTests.swift
    Tests/FenTests/CLIRunnerTests.swift
    Tests/FenTests/CLIRunnerE2ETest.swift
)

# --- Gate 1: Lint (project's existing linter/config) ---
log "Gate 1/6: swiftformat --lint + swiftlint"
swiftformat --lint . 2>&1 | tee "$RUN_DIR/01-swiftformat.log" || fail "swiftformat --lint found unformatted files"
swiftlint 2>&1 | tee "$RUN_DIR/01-swiftlint.log"
if grep -qE "error:" "$RUN_DIR/01-swiftlint.log"; then
    fail "swiftlint reported errors"
fi
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md; rule 2.2)"
if grep -rn "URLSession" Shared/CLI CLI 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log" | grep -q .; then
    fail "URLSession usage found -- the CLI is local, must not add network calls"
fi
log "Gate 1/6: no dynamic code execution introduced (rule 2.1)"
if grep -rn "Process(\|NSAppleScript\|eval(" Shared/CLI CLI \
    2>/dev/null | tee "$RUN_DIR/01-dynexec-grep.log" | grep -q .; then
    fail "dynamic code execution API found in CLI files"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS CLI Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (CLIRunnerIsolationTests)"
if [ ! -f Tests/FenTests/CLIRunnerIsolationTests.swift ]; then
    fail "CLIRunnerIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter CLIRunnerIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- two concurrent runs cross-contaminated, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new CLI files"
if grep -rnE "TODO|FIXME" "${CLI_FILES[@]}" "${CLI_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in CLI files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (CLIRunnerTests)"
if [ ! -f Tests/FenTests/CLIRunnerTests.swift ]; then
    fail "CLIRunnerTests.swift does not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter CLIRunnerTests 2>&1 | tee "$RUN_DIR/05-CLIRunnerTests.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "CLIRunnerTests failed, or no tests actually ran"

# --- Gate 6: E2E-style test of the real CLI flow + full suite + real binary invocation ---
log "Gate 6/6: E2E test (CLIRunnerE2ETest) + full local test suite + real fen-export binary"
if [ ! -f Tests/FenTests/CLIRunnerE2ETest.swift ]; then
    fail "CLIRunnerE2ETest.swift does not exist yet -- nothing to run for gate 6"
fi
swift test --no-parallel --filter CLIRunnerE2ETest 2>&1 | tee "$RUN_DIR/06-e2e.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "CLIRunnerE2ETest failed, or no tests actually ran"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "Gate 6/6: real fen-export binary, built and invoked against a fixture file"
swift build --product fen-export 2>&1 | tee "$RUN_DIR/06-build-cli.log" || fail "fen-export binary failed to build"
FIXTURE_DIR="$RUN_DIR/fixture"
mkdir -p "$FIXTURE_DIR"
printf '# CLI smoke test\n\nHello from the harness.\n' > "$FIXTURE_DIR/smoke.md"
BINARY_PATH="$(swift build --product fen-export --show-bin-path 2>>"$RUN_DIR/06-build-cli.log")/fen-export"
"$BINARY_PATH" "$FIXTURE_DIR/smoke.md" --output-dir "$FIXTURE_DIR" 2>&1 | tee "$RUN_DIR/06-cli-run.log"
if [ ! -f "$FIXTURE_DIR/smoke.html" ]; then
    fail "real fen-export binary invocation did not produce smoke.html"
fi
if ! grep -q "Hello from the harness" "$FIXTURE_DIR/smoke.html"; then
    fail "real fen-export binary output did not contain the expected fixture content"
fi

log "All 6 gates passed. Run log: $RUN_DIR"
