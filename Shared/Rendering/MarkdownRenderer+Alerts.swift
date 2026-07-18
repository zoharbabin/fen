import Foundation

/// Alerts extension (`> [!NOTE]` etc. -> styled alert block, issue #29). Split from
/// `MarkdownRenderer.swift` to keep that file under swiftlint's file/type length limits.
extension MarkdownRenderer {
    /// One of GitHub's 5 alert types -- see
    /// https://github.com/zoharbabin/fen/issues/29's Phase 1 comment. `marker` is always
    /// uppercase (matching is case-insensitive; the captured marker is normalized to this
    /// before lookup) and `className`/`title` drive the emitted CSS hook / human-readable label.
    struct AlertType {
        let marker: String
        let className: String
        let title: String
    }

    static let alertTypes: [AlertType] = [
        AlertType(marker: "NOTE", className: "note", title: "Note"),
        AlertType(marker: "TIP", className: "tip", title: "Tip"),
        AlertType(marker: "IMPORTANT", className: "important", title: "Important"),
        AlertType(marker: "WARNING", className: "warning", title: "Warning"),
        AlertType(marker: "CAUTION", className: "caution", title: "Caution"),
    ]

    /// Matches a structural tag this pass needs to track blockquote/list-item nesting:
    /// `<blockquote>`, `</blockquote>`, an opening `<li>` (with or without attributes), `</li>`.
    static let alertStructurePattern = #"<blockquote>|</blockquote>|<li(?:>| [^>]*>)|</li>"#

    /// A qualifying blockquote's content must open with the marker alone on its own line:
    /// optional whitespace, `<p>`, `[!TYPE]`, then either the paragraph closing immediately
    /// (marker-only alert) or a newline before any body text.
    static let alertMarkerPattern =
        #"\s*<p>\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\](</p>|\n)"#

    /// Rewrites a top-level `<blockquote>` whose content starts with a bare `[!NOTE]`/`[!TIP]`/
    /// `[!IMPORTANT]`/`[!WARNING]`/`[!CAUTION]` marker line into a styled alert block -- GitHub's
    /// Alerts syntax, which cmark-gfm has no syntax extension for (confirmed directly against
    /// this renderer: it emits that marker as literal paragraph text -- see issue #29). Applied
    /// as an HTML post-processing pass over the already-rendered string, following the exact
    /// precedent `applyHighlightMarkup` established for a Markdown feature with no cmark-gfm
    /// extension to hook into.
    ///
    /// Per GitHub's own rule ("Alerts cannot be nested within other elements"), a blockquote
    /// nested inside another blockquote, or inside a list item, never qualifies -- tracked here
    /// via a single linear scan of blockquote/list-item open-close tags rather than a full DOM
    /// walk, since cmark's own HTML output is always well-formed.
    func applyAlertMarkup(to html: String) -> String {
        let nsHTML = html as NSString
        guard let structureRegex = try? NSRegularExpression(pattern: Self.alertStructurePattern) else {
            return html
        }

        let qualifyingBlockquoteRanges = topLevelBlockquoteRanges(in: html, nsHTML: nsHTML, using: structureRegex)
        guard !qualifyingBlockquoteRanges.isEmpty,
              let markerRegex = try? NSRegularExpression(
                  pattern: Self.alertMarkerPattern,
                  options: [.caseInsensitive]
              ) else { return html }

        let replacements = alertReplacements(
            for: qualifyingBlockquoteRanges,
            in: html,
            nsHTML: nsHTML,
            using: markerRegex
        )
        guard !replacements.isEmpty else { return html }

        return applying(replacements, to: nsHTML)
    }

    /// Scans every `<blockquote>`/`</blockquote>`/`<li>`/`</li>` tag once and returns the ranges
    /// of `<blockquote>` open tags that are neither nested inside another blockquote nor inside
    /// a list item.
    private func topLevelBlockquoteRanges(
        in html: String,
        nsHTML: NSString,
        using structureRegex: NSRegularExpression
    ) -> [NSRange] {
        var blockquoteDepth = 0
        var listItemDepth = 0
        var qualifyingRanges: [NSRange] = []

        let fullRange = NSRange(location: 0, length: nsHTML.length)
        for match in structureRegex.matches(in: html, range: fullRange) {
            let token = nsHTML.substring(with: match.range)
            if token == "<blockquote>" {
                if blockquoteDepth == 0, listItemDepth == 0 {
                    qualifyingRanges.append(match.range)
                }
                blockquoteDepth += 1
            } else if token == "</blockquote>" {
                blockquoteDepth = max(0, blockquoteDepth - 1)
            } else if token == "</li>" {
                listItemDepth = max(0, listItemDepth - 1)
            } else {
                listItemDepth += 1
            }
        }
        return qualifyingRanges
    }

    /// For each qualifying blockquote, checks whether it's immediately followed by a recognized
    /// `[!TYPE]` marker and, if so, builds the range/text replacement that swaps the plain
    /// `<blockquote>` + marker paragraph for the styled alert opening.
    private func alertReplacements(
        for blockquoteRanges: [NSRange],
        in html: String,
        nsHTML: NSString,
        using markerRegex: NSRegularExpression
    ) -> [(range: NSRange, text: String)] {
        var replacements: [(range: NSRange, text: String)] = []
        for blockquoteRange in blockquoteRanges {
            let searchStart = blockquoteRange.location + blockquoteRange.length
            let searchRange = NSRange(location: searchStart, length: nsHTML.length - searchStart)
            guard let markerMatch = markerRegex.firstMatch(in: html, range: searchRange),
                  markerMatch.range.location == searchStart,
                  let alert = Self.alertTypes.first(where: {
                      $0.marker == nsHTML.substring(with: markerMatch.range(at: 1)).uppercased()
                  }) else { continue }

            let terminator = nsHTML.substring(with: markerMatch.range(at: 2))
            let titleParagraph = "<p class=\"markdown-alert-title\">\(alert.title)</p>"
            let replacementText = terminator == "</p>"
                ? "<blockquote class=\"markdown-alert markdown-alert-\(alert.className)\">\n\(titleParagraph)"
                : "<blockquote class=\"markdown-alert markdown-alert-\(alert.className)\">\n\(titleParagraph)\n<p>"

            let combinedLength = (markerMatch.range.location + markerMatch.range.length) - blockquoteRange.location
            replacements.append((NSRange(location: blockquoteRange.location, length: combinedLength), replacementText))
        }
        return replacements
    }

    /// Splices a set of non-overlapping, location-ordered replacements into `nsHTML`.
    private func applying(_ replacements: [(range: NSRange, text: String)], to nsHTML: NSString) -> String {
        var result = ""
        var cursor = 0
        for replacement in replacements {
            result += nsHTML.substring(with: NSRange(location: cursor, length: replacement.range.location - cursor))
            result += replacement.text
            cursor = replacement.range.location + replacement.range.length
        }
        result += nsHTML.substring(with: NSRange(location: cursor, length: nsHTML.length - cursor))
        return result
    }
}
