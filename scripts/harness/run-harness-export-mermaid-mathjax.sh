#!/bin/bash
# Regression gate for Mermaid/MathJax rendering in export/print/CLI/clipboard output (issue
# #84: https://github.com/zoharbabin/fen/issues/84). Runs every gate from that issue's
# harnessed-build spec (see issue #84's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-export-mermaid-mathjax.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/export-mermaid-mathjax-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
mkdir -p "$RUN_DIR"

log() { echo -e "\n\033[1;34m==> $1\033[0m"; }
fail() {
    echo -e "\033[1;31mFAILED: $1\033[0m" >&2
    exit 1
}

FEATURE_FILES=(
    Shared/Rendering/HTMLComposer.swift
    Shared/Rendering/PDFRenderer.swift
)
FEATURE_TEST_FILES=(
    Tests/FenTests/ExportPDFIsolationTests.swift
    Tests/FenTests/PDFRendererTests.swift
    Tests/FenTests/ExportMermaidMathJaxE2ETest.swift
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
    fail "URLSession usage found -- Mermaid/MathJax export rendering must stay local, no network calls"
fi
log "Gate 1/6: no dynamic code execution introduced (rule 2.1)"
if grep -rn "Process(\|NSAppleScript\|eval(" "${FEATURE_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/01-dynexec-grep.log" | grep -q .; then
    fail "dynamic code execution API found in Mermaid/MathJax export feature files"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (ExportPDFIsolationTests)"
if [ ! -f Tests/FenTests/ExportPDFIsolationTests.swift ]; then
    fail "ExportPDFIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter ExportPDFIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- PDF export state leaked across instances, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in touched Mermaid/MathJax export feature files"
if grep -rnE "TODO|FIXME" "${FEATURE_FILES[@]}" "${FEATURE_TEST_FILES[@]}" \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in Mermaid/MathJax export feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (PDFRendererTests -- bounded timeout when completion signal never fires)"
if [ ! -f Tests/FenTests/PDFRendererTests.swift ]; then
    fail "PDFRendererTests.swift does not exist yet -- nothing to run for gate 5"
fi
swift test --no-parallel --filter PDFRendererTests 2>&1 | tee "$RUN_DIR/05-PDFRendererTests.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "PDFRendererTests failed, or no tests actually ran"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E test (ExportMermaidMathJaxE2ETest -- real WKWebView render of exported/printed HTML)"
if [ ! -f Tests/FenTests/ExportMermaidMathJaxE2ETest.swift ]; then
    fail "ExportMermaidMathJaxE2ETest.swift does not exist yet -- nothing to run for gate 6"
fi
swift test --no-parallel --filter ExportMermaidMathJaxE2ETest 2>&1 | tee "$RUN_DIR/06-e2e.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ExportMermaidMathJaxE2ETest failed, or no tests actually ran"
log "Gate 6/6: full local test suite (no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
