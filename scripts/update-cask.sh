#!/usr/bin/env bash
# Points Casks/fen.rb at a published release: sets the version and the zip's sha256.
# Refuses a build that Gatekeeper doesn't accept as notarized.
# Usage: scripts/update-cask.sh v0.5.2
set -euo pipefail

tag="${1:?usage: scripts/update-cask.sh vX.Y.Z}"
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

gh release download "$tag" -R zoharbabin/fen -p Fen.app.zip -D "$work"
ditto -x -k "$work/Fen.app.zip" "$work/app"
if ! spctl -a -vv "$work/app/Fen.app" 2>&1 | grep -q "Notarized Developer ID"; then
    echo "error: $tag is not signed and notarized. Not updating the cask." >&2
    exit 1
fi

sha="$(shasum -a 256 "$work/Fen.app.zip" | cut -d' ' -f1)"
cask="$root/Casks/fen.rb"
sed -i '' -E "s/^  version \".*\"/  version \"${tag#v}\"/; s/^  sha256 \".*\"/  sha256 \"$sha\"/" "$cask"
echo "Casks/fen.rb -> ${tag#v} ($sha)"
