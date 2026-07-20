import Foundation
#if os(macOS)
    import AppKit
#else
    import UIKit
    import UniformTypeIdentifiers
#endif

public extension Notification.Name {
    /// Posted by macOS's "Copy as Raw HTML" menu command (`macOS/CopyCommands.swift`) to ask the
    /// focused `SplitEditorView` to perform the copy -- mirrors `.exportToHTML` (issue #31).
    static let copyAsRawHTML = Notification.Name("copyAsRawHTML")
    /// Posted by macOS's "Copy as Rich Text Formatted" menu command -- mirrors `.copyAsRawHTML`.
    static let copyAsRichTextFormatted = Notification.Name("copyAsRichTextFormatted")
}

/// Puts a document's rendered output directly on the system pasteboard (issue #33) -- "Copy as
/// Raw HTML" and "Copy as Rich Text Formatted" skip the file-export round trip
/// `DocumentHTMLExporter` (issue #31) otherwise requires. Composes via that same exporter's
/// `.selfContained` mode (the only mode that makes sense for a clipboard payload: there's no
/// destination directory to resolve a `linkedAssets` folder against, and every embedded image
/// needs to travel with the copied content as one self-contained blob). Holds no stored state:
/// both methods are pure functions of their arguments, so two concurrent calls composing
/// different documents never share or corrupt each other's *composed* output (rule 1.1) -- the
/// final pasteboard write itself targets the one OS-owned general pasteboard, the same shared
/// resource every app's copy action writes to, not state Fen owns or could isolate away.
public struct ClipboardExporter: Sendable {
    /// Matches `ExportAssetResolver`'s own `<img src="...">` pattern (issue #31) -- reused here,
    /// not duplicated, to find any reference `.selfContained` composition left un-inlined (an
    /// oversized image, or one already an absolute `http(s):` URL) so it can be stripped before
    /// rich-text conversion.
    private static let imgTagRegex = try? NSRegularExpression(
        pattern: #"<img\b[^>]*?\ssrc=("|')(?!data:)((?:(?!\1).)*)\1[^>]*>"#, options: [.caseInsensitive]
    )

    public init() {}

    /// Composes `markdown` into self-contained export HTML (issue #31's `DocumentHTMLExporter`,
    /// rule 5.1 -- no HTML composition logic duplicated here).
    ///
    /// Not `private`: `ClipboardExporterIsolationTests`/`ClipboardExporterTests` (issue #33) call
    /// this directly to assert on pure composition output, without racing the one real,
    /// process-wide OS pasteboard `copyAsRawHTML`/`copyAsRichTextFormatted` write to.
    func composeHTML(markdown: String, documentURL: URL?, preferences: Preferences) -> String {
        DocumentHTMLExporter().export(
            markdown: markdown, documentURL: documentURL, preferences: preferences, mode: .selfContained
        ).html
    }

    /// Removes every `<img>` tag whose `src` isn't already a `data:` URI -- a remote or
    /// unresolvable reference `ExportAssetResolver` deliberately left untouched (issue #31, rule
    /// 2.3). `NSAttributedString`'s own HTML importer performs a live network fetch for a
    /// remaining `http`/`https` `src` when converting to rich text, independent of anything
    /// `ExportAssetResolver` does -- confirmed by a local repro before writing this. Stripping
    /// such tags first is the only guard available, since the importer runs synchronously inside
    /// one call with no hook to intercept its own resource loading (rule 2.3).
    ///
    /// Not `private`: `ClipboardExporterSecurityTests` calls this directly to prove a remaining
    /// remote `<img>` reference is actually removed before `attributedString(from:)` ever sees it.
    func strippingNonDataImages(from html: String) -> String {
        guard let regex = Self.imgTagRegex else { return html }
        let range = NSRange(html.startIndex ..< html.endIndex, in: html)
        return regex.stringByReplacingMatches(in: html, range: range, withTemplate: "")
    }

    /// Converts `html` to an `NSAttributedString` via its rich-text HTML importer, or `nil` if
    /// the conversion produces no usable content (rule 3: a malformed document degrades to no
    /// rich-text representation, rather than crashing "Copy as Rich Text Formatted").
    ///
    /// Not `private`: `ClipboardExporterTests` calls this directly to prove a malformed document
    /// degrades to `nil` rather than throwing.
    func attributedString(from html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        var docAttributes: NSDictionary?
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html],
            documentAttributes: &docAttributes
        )
    }

    #if os(macOS)
        /// Writes composed self-contained HTML to the general pasteboard as plain text only --
        /// deliberately no `.html` type. Declaring `.html` would let any app that prefers a rich
        /// paste (Mail, Word, Teams, Slack) render the markup instead of showing it, defeating
        /// the entire point of "Copy as Raw HTML": pasting the literal `<tags>` as text,
        /// everywhere, every time.
        public func copyAsRawHTML(markdown: String, documentURL: URL?, preferences: Preferences) {
            let html = composeHTML(markdown: markdown, documentURL: documentURL, preferences: preferences)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(html, forType: .string)
        }

        /// Writes composed HTML's rich-text (`.rtf`) conversion to the general pasteboard, plus
        /// an `.html` type for apps that prefer it and a rendered-plain-text `.string` fallback
        /// for apps that understand neither.
        public func copyAsRichTextFormatted(markdown: String, documentURL: URL?, preferences: Preferences) {
            let html = composeHTML(markdown: markdown, documentURL: documentURL, preferences: preferences)
            let strippedHTML = strippingNonDataImages(from: html)
            let attributed = attributedString(from: strippedHTML)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if let attributed, let rtfData = rtfData(from: attributed) {
                pasteboard.setData(rtfData, forType: .rtf)
            }
            pasteboard.setString(html, forType: .html)
            pasteboard.setString(attributed?.string ?? markdown, forType: .string)
        }
    #else
        /// iOS half of `copyAsRawHTML` -- same plain-text-only write, `UIPasteboard.general` in
        /// place of `NSPasteboard.general`.
        public func copyAsRawHTML(markdown: String, documentURL: URL?, preferences: Preferences) {
            let html = composeHTML(markdown: markdown, documentURL: documentURL, preferences: preferences)
            UIPasteboard.general.items = [[UTType.utf8PlainText.identifier: html]]
        }

        /// iOS half of `copyAsRichTextFormatted` -- same rich-text conversion and fallbacks,
        /// `UIPasteboard.general` in place of `NSPasteboard.general`. `UIPasteboard` has no
        /// dedicated RTF UTType constant, so `.rtf`'s own identifier is used directly, matching
        /// how RTF content is conventionally declared on iOS's pasteboard.
        public func copyAsRichTextFormatted(markdown: String, documentURL: URL?, preferences: Preferences) {
            let html = composeHTML(markdown: markdown, documentURL: documentURL, preferences: preferences)
            let attributed = attributedString(from: strippingNonDataImages(from: html))
            var item: [String: Any] = [
                UTType.html.identifier: html,
                UTType.utf8PlainText.identifier: attributed?.string ?? markdown,
            ]
            if let attributed, let rtfData = rtfData(from: attributed) {
                item[UTType.rtf.identifier] = rtfData
            }
            UIPasteboard.general.items = [item]
        }
    #endif

    /// Converts `attributed` to RTF data, or `nil` if the conversion fails (rule 3). `NSAttributedString.rtf(from:)`
    /// is AppKit-only, so this uses the cross-platform `data(from:documentAttributes:)` API instead, letting both
    /// platforms share this call site.
    private func rtfData(from attributed: NSAttributedString) -> Data? {
        try? attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }
}
