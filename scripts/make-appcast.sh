#!/usr/bin/env bash
#
# make-appcast.sh — sign a release zip for Sparkle and write a one-item appcast (issue #39).
#
#     SPARKLE_PRIVATE_KEY="$(cat key-file)" ./scripts/make-appcast.sh dist/Fen.app.zip 1.2.0 345 dist/appcast.xml
#
# Arguments: zip, marketing version (no "v"), build number (CFBundleVersion), output path.
# The private key comes from the environment and is piped to sign_update, never written to disk.
# The feed is the "latest" release, so one item is enough.
#
set -euo pipefail

[ "$#" -eq 4 ] || { echo "usage: $0 <zip> <version> <build> <output>" >&2; exit 2; }
ZIP="$1" VERSION="${2#v}" BUILD="$3" OUT="$4"
: "${SPARKLE_PRIVATE_KEY:?SPARKLE_PRIVATE_KEY is not set}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"
[ -x "$SIGN_UPDATE" ] || { echo "!! sign_update not found at $SIGN_UPDATE (run swift package resolve)" >&2; exit 1; }
[ -f "$ZIP" ] || { echo "!! $ZIP not found" >&2; exit 1; }

REPO_URL="https://github.com/zoharbabin/fen"
SIGNATURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"
case "$SIGNATURE" in
    sparkle:edSignature=*length=*) ;;
    *) echo "!! sign_update gave an unexpected answer" >&2; exit 1 ;;
esac

cat > "$OUT" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Fen</title>
        <link>$REPO_URL</link>
        <item>
            <title>Fen $VERSION</title>
            <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
            <enclosure url="$REPO_URL/releases/download/v$VERSION/$(basename "$ZIP")" type="application/octet-stream" $SIGNATURE/>
        </item>
    </channel>
</rss>
XML
xmllint --noout "$OUT"
echo "==> Wrote $OUT"
