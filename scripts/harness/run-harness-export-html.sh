#!/bin/bash
# Regression gate for HTML export (issue #31:
# https://github.com/zoharbabin/fen/issues/31). Runs every gate from that issue's
# harnessed-build spec (see issue #31's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-export-html.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/export-html-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
log "Gate 1/6: no networking APIs introduced (Fen's local-first trust model, CLAUDE.md; rule 2.3)"
if grep -rn "URLSession" Shared macOS iOS 2>/dev/null | tee "$RUN_DIR/01-urlsession-grep.log"; then
    fail "URLSession usage found -- HTML export is local file I/O, must not add network calls"
fi
log "Gate 1/6: no dynamic code execution introduced (rule 2.1)"
if grep -rn "Process(\|NSAppleScript\|eval(" \
    Shared/Rendering/ExportAssetResolver.swift Shared/Rendering/HTMLComposer.swift \
    Shared/Rendering/DocumentHTMLExporter.swift Shared/Rendering/HTMLExportController.swift \
    Shared/Rendering/HTMLExportDocument.swift macOS/ExportHTMLCommands.swift \
    2>/dev/null | tee "$RUN_DIR/01-dynexec-grep.log" | grep -q .; then
    fail "dynamic code execution API found in export files"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (ExportHTMLIsolationTests)"
if [ ! -f Tests/FenTests/ExportHTMLIsolationTests.swift ]; then
    fail "ExportHTMLIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter ExportHTMLIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed"; then
    fail "isolation test failed, or no tests actually ran -- export state leaked across instances, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new export-html feature files"
if grep -rnE "TODO|FIXME" \
    Shared/Rendering/ExportAssetResolver.swift Shared/Rendering/HTMLComposer.swift \
    Shared/Rendering/DocumentHTMLExporter.swift Shared/Rendering/HTMLExportController.swift \
    Shared/Rendering/HTMLExportDocument.swift macOS/ExportHTMLCommands.swift \
    Tests/FenTests/ExportHTMLIsolationTests.swift Tests/FenTests/ExportAssetResolverTests.swift \
    Tests/FenTests/ExportAssetResolverSecurityTests.swift Tests/FenTests/ExportHTMLComposerTests.swift \
    Tests/FenTests/ExportHTMLE2ETest.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in export-html feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (ExportAssetResolverTests, ExportAssetResolverSecurityTests, ExportHTMLComposerTests)"
for suite in ExportAssetResolverTests ExportAssetResolverSecurityTests ExportHTMLComposerTests; do
    if [ ! -f "Tests/FenTests/${suite}.swift" ]; then
        fail "${suite}.swift does not exist yet -- nothing to run for gate 5"
    fi
    swift test --no-parallel --filter "$suite" 2>&1 | tee "$RUN_DIR/05-${suite}.log" \
        | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
        || fail "$suite failed, or no tests actually ran"
done

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E test (ExportHTMLE2ETest -- real export flow against fixture document + sidecar image)"
if [ ! -f Tests/FenTests/ExportHTMLE2ETest.swift ]; then
    fail "ExportHTMLE2ETest.swift does not exist yet -- nothing to run for gate 6"
fi
swift test --no-parallel --filter ExportHTMLE2ETest 2>&1 | tee "$RUN_DIR/06-e2e.log" \
    | grep -qE "Test run with [1-9][0-9]* tests? in [1-9][0-9]* suites? passed" \
    || fail "ExportHTMLE2ETest failed, or no tests actually ran"
log "Gate 6/6: full local test suite (no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
