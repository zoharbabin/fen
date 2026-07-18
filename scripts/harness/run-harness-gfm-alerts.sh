#!/bin/bash
# Regression gate for GFM alert/callout syntax rendering (issue #29:
# https://github.com/zoharbabin/fen/issues/29). Runs every gate from that issue's
# harnessed-build spec (see issue #29's Phase 1 comment) in order and fails loud on the
# first non-zero exit.
#
# Usage: scripts/harness/run-harness-gfm-alerts.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/gfm-alerts-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
    fail "URLSession usage found -- alert rendering is a local HTML transform, must not add network calls"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS Tests 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Isolation test (rule 1.1) ---
log "Gate 3/6: isolation test (GFMAlertsIsolationTests)"
if [ ! -f Tests/FenTests/GFMAlertsIsolationTests.swift ]; then
    fail "GFMAlertsIsolationTests.swift does not exist yet -- nothing to run for gate 3"
fi
if ! swift test --no-parallel --filter GFMAlertsIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    | grep -qE "Executed [1-9][0-9]* test"; then
    fail "isolation test failed, or no tests actually ran -- alert transform leaked state, or filter matched nothing"
fi

# --- Gate 4: Dead-code scan ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new alert files"
if grep -rnE "TODO|FIXME" \
    Shared/Rendering/MarkdownRenderer.swift Shared/Models/Preferences.swift \
    Tests/FenTests/GFMAlertsIsolationTests.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log" | grep -q .; then
    fail "TODO/FIXME marker found in alert feature files"
fi

# --- Gate 5: Unit/integration tests proving each Phase-1 rule ---
log "Gate 5/6: unit tests (MarkdownRendererTests alert cases, PreviewThemeCoverageTests, GFMFeatureCoverageTests)"
swift test --no-parallel --filter MarkdownRendererTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "MarkdownRendererTests failed"
swift test --no-parallel --filter PreviewThemeCoverageTests 2>&1 | tee "$RUN_DIR/05-theme.log" \
    || fail "PreviewThemeCoverageTests failed"
swift test --no-parallel --filter GFMFeatureCoverageTests 2>&1 | tee "$RUN_DIR/05-coverage.log" \
    || fail "GFMFeatureCoverageTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
# No dedicated UI-test target: alert rendering has no interactive surface (no button/dialog),
# just rendered output in the preview pane -- the established E2E bar for that shape of
# feature is a real WKWebView driven end-to-end (see GFMFeatureCoverageTests.swift,
# PreviewThemeCoverageTests.swift, neither of which have a separate XCUITest either).
# Re-run the full suite here as the recorded proof this gate requires.
log "Gate 6/6: full local test suite (recorded proof of the real flow, no regressions elsewhere)"
swift test --no-parallel 2>&1 | tee "$RUN_DIR/06-full-suite.log" \
    || fail "full test suite failed"

log "All 6 gates passed. Run log: $RUN_DIR"
