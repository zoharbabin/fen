#!/bin/bash
# Turns a CI job's log into a short Markdown report for the run summary (issue #221).
# Read-only: prints to stdout. ci.yml appends the output to $GITHUB_STEP_SUMMARY.
#
#   scripts/ci-report.sh tests  <swift-test.log>
#   scripts/ci-report.sh lint   <swiftformat.log> <swiftlint.log>
#   scripts/ci-report.sh xcode  <title> <xcodebuild.log> <seconds>
set -eu

duration() { # 787.4 -> 13m 07s
    local s=${1%.*}
    [ -n "$s" ] || s=0
    if [ "$s" -ge 60 ]; then printf '%dm %02ds' $((s / 60)) $((s % 60)); else printf '%ds' "$s"; fi
}

tests() {
    local log=$1 run count suites state secs build issues
    echo "## 🧪 Swift tests"
    echo
    if [ ! -f "$log" ]; then
        echo "❌ No log. A step before \`swift test\` failed."
        return
    fi
    run=$(grep -E 'Test run with [0-9]+ tests? in [0-9]+ suites? (passed|failed)' "$log" | tail -1 || true)
    if [ -z "$run" ]; then
        echo "❌ No test results in the log. The build probably failed before the tests started."
        echo
        echo '```text'
        tail -n 20 "$log"
        echo '```'
        return
    fi
    count=$(sed -E 's/.*Test run with ([0-9]+) tests?.*/\1/' <<< "$run")
    suites=$(sed -E 's/.*in ([0-9]+) suites?.*/\1/' <<< "$run")
    state=$(sed -E 's/.*suites? (passed|failed).*/\1/' <<< "$run")
    secs=$(sed -E 's/.*after ([0-9.]+) seconds.*/\1/' <<< "$run")
    build=$(sed -nE 's/.*Build complete! \(([0-9.]+)s\).*/\1/p' "$log" | tail -1)
    issues=$(grep -cE '^[^a-zA-Z0-9]*Test .* recorded an issue' "$log" || true)

    echo "| | |"
    echo "|---|---|"
    if [ "$state" = passed ]; then echo "| Result | ✅ passed |"; else echo "| Result | ❌ failed |"; fi
    echo "| Tests | $count in $suites suites |"
    echo "| Test run | $(duration "$secs") |"
    [ -z "$build" ] || echo "| Build | $(duration "$build") |"
    echo "| Issues recorded | $issues |"
    echo
    echo "**Slowest suites**"
    echo
    echo "| Suite | Time |"
    echo "|---|---:|"
    sed -nE 's/^.*(✔|✘) Suite (.*) (passed|failed) after ([0-9.]+) seconds.*/\4\t\2/p' "$log" \
        | sort -t$'\t' -k1,1 -rn | head -8 \
        | while IFS=$'\t' read -r t name; do
            name=${name//|/\\|}
            printf '| %s | %ss |\n' "$name" "$t"
        done
    if [ "$state" = failed ]; then
        echo
        echo "**Failures**"
        echo
        echo '```text'
        grep -E '✘' "$log" | head -n 30
        echo '```'
    fi
}

lint() {
    local format_log=$1 lint_log=$2 needs total violations serious files
    [ -f "$format_log" ] || : > "$format_log"
    [ -f "$lint_log" ] || : > "$lint_log"
    needs=$(sed -nE 's#^([0-9]+)/([0-9]+) files require formatting.*#\1#p' "$format_log" | tail -1)
    total=$(sed -nE 's#^([0-9]+)/([0-9]+) files require formatting.*#\2#p' "$format_log" | tail -1)
    violations=$(sed -nE 's/^Done linting! Found ([0-9]+) violations?, ([0-9]+) serious in ([0-9]+) files?.*/\1/p' "$lint_log" | tail -1)
    serious=$(sed -nE 's/^Done linting! Found ([0-9]+) violations?, ([0-9]+) serious in ([0-9]+) files?.*/\2/p' "$lint_log" | tail -1)
    files=$(sed -nE 's/^Done linting! Found ([0-9]+) violations?, ([0-9]+) serious in ([0-9]+) files?.*/\3/p' "$lint_log" | tail -1)

    echo "## 🧹 Format & lint"
    echo
    echo "| Check | Result | Detail |"
    echo "|---|---|---|"
    if [ -z "$needs" ]; then
        echo "| swiftformat | ❓ no result | see the job log |"
    elif [ "$needs" = 0 ]; then
        echo "| swiftformat | ✅ clean | $total files checked |"
    else
        echo "| swiftformat | ❌ $needs file(s) need formatting | run \`swiftformat .\` |"
    fi
    if [ -z "$serious" ]; then
        echo "| swiftlint | ❓ no result | see the job log |"
    elif [ "$serious" = 0 ]; then
        echo "| swiftlint | ✅ no serious violations | $violations warning(s) in $files files |"
    else
        echo "| swiftlint | ❌ $serious serious violation(s) | $violations in total, $files files |"
    fi
    if [ "${needs:-0}" != 0 ]; then
        echo
        echo "**Files to format**"
        echo
        echo '```text'
        grep -E ': error: ' "$format_log" | sed -E 's#^.*/(Shared|macOS|iOS|CLI|Tests|UITests|FenQuickLook|FenShare)/#\1/#' | head -n 30
        echo '```'
    fi
    if [ "${serious:-0}" != 0 ]; then
        echo
        echo "**Serious violations**"
        echo
        echo '```text'
        grep -E ': error: ' "$lint_log" | sed -E 's#^.*/(Shared|macOS|iOS|CLI|Tests|UITests|FenQuickLook|FenShare)/#\1/#' | head -n 30
        echo '```'
    fi
}

xcode() {
    local title=$1 log=$2 seconds=$3 warnings errors result
    if [ ! -f "$log" ]; then
        printf '## %s\n\n❌ No log. A step before the build failed.\n' "$title"
        return
    fi
    warnings=$(grep -E ': warning: ' "$log" | sed -E 's/^[^ ]*: warning: //' | sort -u | wc -l | tr -d ' ')
    errors=$(grep -cE ': error: ' "$log" || true)
    if grep -q '\*\* BUILD SUCCEEDED \*\*' "$log"; then result="✅ succeeded"; else result="❌ failed"; fi
    echo "## $title"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Build | $result |"
    echo "| Time | $(duration "$seconds") |"
    echo "| Distinct warnings | $warnings |"
    echo "| Errors | $errors |"
    if [ "$errors" != 0 ]; then
        echo
        echo '```text'
        grep -E ': error: ' "$log" | head -n 20
        echo '```'
    fi
}

case ${1:-} in
    tests) tests "$2" ;;
    lint) lint "$2" "$3" ;;
    xcode) xcode "$2" "$3" "$4" ;;
    *) echo "usage: $0 tests|lint|xcode ..." >&2; exit 2 ;;
esac
