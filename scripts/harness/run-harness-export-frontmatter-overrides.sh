#!/bin/bash
# Regression gate for per-document fen: front-matter overrides (theme, TOC) in
# export/print/CLI/clipboard output (issue #85:
# https://github.com/zoharbabin/fen/issues/85). Runs every gate from that issue's
# harnessed-build spec (see issue #85's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-export-frontmatter-overrides.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/export-frontmatter-overrides-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

FEATURE_FILES=(
    Shared/Rendering/HTMLComposer.swift
    Shared/Rendering/DocumentHTMLExporter.swift
    Shared/Rendering/DocumentPDFExporter.swift
    Shared/CLI/ExportCLIRunner.swift
)
FEATURE_TEST_FILES=(
    Tests/FenTests/DocumentPreviewOverridesIsolationTests.swift
    Tests/FenTests/ExportFrontMatterOverridesTests.swift
    Tests/FenTests/ExportFrontMatterOverridesE2ETest.swift
)

# --- Gate 1: Lint (project's existing linter/config) ---
log "Gate 1/6: swiftformat --lint + swiftlint"
swiftformat --lint . 2>&1 | tee "$RUN_DIR/01-swiftformat.log" || fail "swiftformat --lint found unformatted files"
swiftlint 2>&1 | tee "$RUN_DIR/01-swiftlint.log"
if grep -qE "error:" "$RUN_DIR/01-swiftlint.log"; then
    fail "swiftlint reported errors"
fi
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md; rule 2.1)"
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- front-matter override resolution is local, no network calls"
fi
log "Gate 1/6: no dynamic code execution introduced (rule 2.1)"
if grep -rn "Process(\|NSAppleScript\|eval(" "${FEATURE_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/01-dynexec-grep.log" | grep -q .; then
    fail "dynamic code execution API found in front-matter-override export feature files"
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
    fail "isolation test failed, or no tests actually ran -- one document's front-matter override leaked into another's export"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in touched front-matter-override export feature files"
if grep -rnE "TODO|FIXME" "${FEATURE_FILES[@]}" "${FEATURE_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in front-matter-override export feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (ExportFrontMatterOverridesTests -- fallback/degrade cases)"
if [ ! -f Tests/FenTests/ExportFrontMatterOverridesTests.swift ]; then
    fail "ExportFrontMatterOverridesTests.swift does not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter ExportFrontMatterOverridesTests 2>&1 | tee "$RUN_DIR/05-verify.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ExportFrontMatterOverridesTests failed, or no tests actually ran"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E test (ExportFrontMatterOverridesE2ETest -- real export/CLI flow with fen: front matter)"
if [ ! -f Tests/FenTests/ExportFrontMatterOverridesE2ETest.swift ]; then
    fail "ExportFrontMatterOverridesE2ETest.swift does not exist yet -- nothing to run for gate 6"
fi
swift test --no-parallel --filter ExportFrontMatterOverridesE2ETest 2>&1 | tee "$RUN_DIR/06-e2e.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ExportFrontMatterOverridesE2ETest failed, or no tests actually ran"
log "Gate 6/6: full local test suite (no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
