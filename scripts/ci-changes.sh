#!/bin/bash
# Decides which CI jobs a change needs (issue #221). Used by the "Detect changes" job in ci.yml.
#
#   scripts/ci-changes.sh <base> [head]    base "all" or empty runs every job
#
# Writes lint=true|false, tests=..., builds=..., docs=..., cask=..., workflows=... to $GITHUB_OUTPUT
# (stdout when unset) and a Markdown report to $GITHUB_STEP_SUMMARY (stderr when unset).
#
# The rules are the `case` below. A path that no rule knows runs the Swift jobs, so a new folder
# never skips a check by accident. The table in docs/ARCHITECTURE.md#ci-and-releases mirrors it.
set -euo pipefail

base=${1:-}
head=${2:-HEAD}
out=${GITHUB_OUTPUT:-/dev/stdout}
summary=${GITHUB_STEP_SUMMARY:-/dev/stderr}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
TAB=$'\t'
hits=$work/hits    # "<job><TAB><path or reason>", one line per rule that fired
files=$work/files  # "<status><TAB><path>"

hit() { printf '%s\t%s\n' "$1" "$2" >> "$hits"; }
: > "$hits"

if [ -z "$base" ] || [ "$base" = all ] || [[ $base =~ ^0+$ ]]; then
    : > "$files"
    reason="no base commit to compare with"
    hit all "$reason"
elif git diff --name-status --no-renames "$base...$head" > "$files" 2> /dev/null; then
    :
else
    : > "$files"
    reason="could not diff $base...$head"
    hit all "$reason"
fi

while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue

    # A removed or moved file can leave a dead link behind, in a file this change did not touch.
    [ "$status" != D ] || hit docs "$path (removed)"

    case "$path" in
        # The CI itself: run everything, so a broken job shows up in its own PR.
        .github/workflows/ci.yml | scripts/ci-*) hit all "$path" ;;
        .github/workflows/*) hit workflows "$path" ;;
        .github/* | LICENSE* | .gitignore | .gitattributes) ;;

        Casks/* | scripts/update-cask.sh) hit cask "$path" ;;
        .swiftlint.yml | .swiftformat) hit lint "$path" ;;

        # Tests read files here, such as the Info.plists and assets/demo.md.
        Shared/* | macOS/* | iOS/* | CLI/* | FenQuickLook/* | FenShare/* | Dependency/* | assets/* | Package.swift | Package.resolved)
            hit tests "$path"
            hit builds "$path"
            ;;
        Tests/*) hit tests "$path" ;;
        project.yml) hit builds "$path" ;;

        # Not compiled by CI: UI tests, release and dev scripts, docs and the site.
        UITests/* | scripts/* | docs/* | site/* | *.md) ;;

        *)
            hit tests "$path (not covered by a rule)"
            hit builds "$path (not covered by a rule)"
            ;;
    esac

    case "$path" in
        *.swift | .swiftformat) hit lint "$path" ;;
        *.md | *.html | docs/* | site/*) hit docs "$path" ;;
    esac
done < "$files"

# One line per job: its output name, its display name, and the reason it would be skipped.
jobs=$(cat <<'EOF'
lint|🧹 Format & lint|no Swift file or lint config changed
tests|🧪 Swift tests|no source, test, asset or package change
builds|📱 Xcode builds|no app source or project.yml change
docs|🔗 Doc & site links|no Markdown, HTML or site change, and no file removed
cask|🍺 Homebrew cask|Casks/ did not change
workflows|⚙️ Workflow lint|no workflow file changed
EOF
)

total=$(grep -c . "$files" || true)
{
    echo "## 🔎 What changed"
    echo
    if grep -q "^all$TAB" "$hits"; then
        echo "Compared: **everything runs** ($(grep -m1 "^all$TAB" "$hits" | cut -f2))."
    else
        echo "Compared \`${base:0:7}...${head:0:7}\`: **$total changed file(s)**."
    fi
    echo
    echo "| Job | Runs? | Why |"
    echo "|---|---|---|"
} > "$summary"

while IFS='|' read -r key name skip; do
    if grep -q "^all$TAB" "$hits"; then
        why=$(grep -m1 "^all$TAB" "$hits" | cut -f2)
        run=true
    elif grep -q "^$key$TAB" "$hits"; then
        run=true
        why=$(grep -m1 "^$key$TAB" "$hits" | cut -f2)
    else
        run=false
        why=$skip
    fi
    echo "$key=$run" >> "$out"
    if [ "$run" = true ]; then
        echo "| $name | ▶️ run | \`${why//\`/\'}\` |" >> "$summary"
    else
        echo "| $name | ⏭️ skip | $why |" >> "$summary"
    fi
done <<< "$jobs"

if [ "$total" -gt 0 ]; then
    {
        echo
        echo "<details><summary>Changed files ($total)</summary>"
        echo
        echo '```text'
        head -n 200 "$files" | tr '\t' ' '
        [ "$total" -le 200 ] || echo "... and $((total - 200)) more"
        echo '```'
        echo
        echo "</details>"
    } >> "$summary"
fi
