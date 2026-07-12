#!/bin/bash
# Regression gate for the default-.md-editor feature (issue #14:
# https://github.com/zoharbabin/fen/issues/14). Runs every gate from that issue's
# harnessed-build spec in order and fails loud on the first non-zero exit.
#
# Usage: scripts/harness/run-harness-default-editor.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

RUN_DIR=".harness-runs/default-editor-$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)"
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
    fail "URLSession usage found -- default-editor feature must not introduce network calls"
fi
log "Gate 1/6: no Fen-owned plaintext recents persistence introduced (rule 2.2)"
# Recents must stay delegated to NSDocumentController's own secure-bookmark mechanism --
# a new UserDefaults/custom-file write of raw recent-document paths would regress rule 2.2.
if grep -rnE 'UserDefaults.*[Rr]ecent|[Rr]ecent.*UserDefaults' Shared macOS iOS 2>/dev/null \
    | tee "$RUN_DIR/01-recents-persistence-grep.log" | grep -q .; then
    fail "found a custom UserDefaults-backed recents store -- must use NSDocumentController/security-scoped bookmarks instead"
fi
log "Gate 1/6: macOS and iOS Info.plist stay in sync on document-type/UTI keys (rule 5.1/7.1)"
# CFBundleTypeIconFile is intentionally excluded from this comparison: Finder
# document icons are a macOS-only concept (no Finder/document-icon equivalent
# exists on iOS), so it's expected to be macOS-only, not a sync divergence.
# Everything that defines UTI identity (extensions, roles, conforms-to) must
# still match byte-for-byte.
# Sorted, since PlistBuddy's `Print` walks an NSDictionary whose key order isn't part of the
# plist format and isn't guaranteed stable across edits (confirmed: adding
# CFBundleTypeIconFile to macOS/Info.plist reordered unrelated sibling keys in `Print`'s output
# without changing any value) -- sorting makes this a content comparison, not an incidental
# ordering one.
extract_doc_type_block() {
    {
        /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" "$1" 2>/dev/null | grep -v "CFBundleTypeIconFile"
        /usr/libexec/PlistBuddy -c "Print :UTImportedTypeDeclarations" "$1" 2>/dev/null
    } | sort
}
extract_doc_type_block macOS/Info.plist > "$RUN_DIR/01-macos-doctypes.log"
extract_doc_type_block iOS/Info.plist > "$RUN_DIR/01-ios-doctypes.log"
if ! diff -u "$RUN_DIR/01-macos-doctypes.log" "$RUN_DIR/01-ios-doctypes.log" > "$RUN_DIR/01-doctypes-diff.log"; then
    cat "$RUN_DIR/01-doctypes-diff.log"
    fail "macOS/Info.plist and iOS/Info.plist diverge on CFBundleDocumentTypes/UTImportedTypeDeclarations"
fi
if ! grep -q "net.daringfireball.markdown" "$RUN_DIR/01-macos-doctypes.log"; then
    fail "macOS/Info.plist no longer declares net.daringfireball.markdown"
fi

# --- Gate 2: SAST scan ---
log "Gate 2/6: semgrep SAST scan"
semgrep scan --config auto --error --quiet Shared macOS iOS 2>&1 | tee "$RUN_DIR/02-semgrep.log" \
    || fail "semgrep reported findings"

# --- Gate 3: Multi-instance/multi-call isolation test ---
log "Gate 3/6: isolation test (DefaultEditorIsolationTests)"
swift test --no-parallel --filter DefaultEditorIsolationTests 2>&1 | tee "$RUN_DIR/03-isolation.log" \
    || fail "isolation test failed -- document/session state leaked across instances"

# --- Gate 4: Dead-code scan + document-icon asset resolution ---
log "Gate 4/6: periphery dead-code scan"
periphery scan --format xcode 2>&1 | tee "$RUN_DIR/04-periphery.log" \
    || fail "periphery found unused code"
log "Gate 4/6: no unfinished-work markers in new default-editor files"
if grep -rnE "TODO|FIXME" \
    Tests/FenTests/DefaultEditor*.swift \
    UITests/FenUITests/DefaultEditorUITests.swift \
    2>/dev/null | tee "$RUN_DIR/04-todo-grep.log"; then
    fail "TODO/FIXME marker found in default-editor feature files"
fi
log "Gate 4/6: CFBundleTypeIconFile resolves to a real file in a freshly built app bundle (rule 5.2/8.1)"
CONFIG=debug ./scripts/build-app.sh 2>&1 | tee "$RUN_DIR/04-build-app.log"
ICON_NAME="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes:0:CFBundleTypeIconFile" \
    dist/Fen.app/Contents/Info.plist 2>/dev/null || true)"
if [ -z "$ICON_NAME" ]; then
    fail "macOS/Info.plist's CFBundleDocumentTypes entry has no CFBundleTypeIconFile key"
fi
if [ ! -f "dist/Fen.app/Contents/Resources/$ICON_NAME.icns" ]; then
    fail "CFBundleTypeIconFile names '$ICON_NAME' but dist/Fen.app/Contents/Resources/$ICON_NAME.icns does not exist"
fi

# --- Gate 5: Unit/integration/security tests proving each Phase-1 rule ---
log "Gate 5/6: unit/security tests (DefaultEditorTests, DefaultEditorSecurityTests)"
swift test --no-parallel --filter DefaultEditorTests 2>&1 | tee "$RUN_DIR/05-unit.log" \
    || fail "DefaultEditorTests failed"
swift test --no-parallel --filter DefaultEditorSecurityTests 2>&1 | tee "$RUN_DIR/05-security.log" \
    || fail "DefaultEditorSecurityTests failed"

# --- Gate 6: E2E test of the real user flow, with recorded proof ---
log "Gate 6/6: E2E UI test (DefaultEditorUITests) -- screenshots attached to test result"
xcodegen generate 2>&1 | tee "$RUN_DIR/06-xcodegen.log"
xcodebuild test \
    -scheme FenMacOSApp \
    -project FenUITesting.xcodeproj \
    -destination 'platform=macOS' \
    -only-testing:FenMacOSUITests/DefaultEditorUITests \
    2>&1 | tee "$RUN_DIR/06-e2e.log" \
    || fail "DefaultEditorUITests E2E run failed"

log "All 6 gates passed. Run log: $RUN_DIR"
