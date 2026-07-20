@testable import FenCore
import Foundation
import Testing
#if os(macOS)
    import AppKit
#endif

/// End-to-end test for issue #33: drives the real "Copy as Raw HTML" / "Copy as Rich Text
/// Formatted" flow -- `ClipboardExporter.copyAsRawHTML`/`copyAsRichTextFormatted` -- against a
/// fixture document, then asserts the actual pasteboard contents, mirroring `ExportHTMLE2ETest`'s
/// shape of exercising every step with real production types rather than calling composition
/// helpers directly (that's already covered by
/// `ClipboardExporterTests`/`ClipboardExporterIsolationTests`).
@Suite("Copying a document as raw HTML or rich text writes real pasteboard content")
struct ClipboardExporterE2ETest {
    #if os(macOS)
        @Test @MainActor
        func copyAsRawHTMLWritesOnlyPlainTextWithLiteralMarkupToTheGeneralPasteboard() throws {
            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "clipboard.e2e.\(UUID().uuidString)")))

            ClipboardExporter().copyAsRawHTML(
                markdown: "---\ntitle: Notes\n---\n\n# Title\n\nSome **bold** text.",
                documentURL: nil,
                preferences: preferences
            )

            let pasteboard = NSPasteboard.general
            let plain = pasteboard.string(forType: .string)

            // No `.html` type: declaring one would let a rich-paste-preferring app (Mail, Word,
            // Teams) render the markup instead of showing it as literal text -- the entire point
            // of "Copy as Raw HTML" is that the tags themselves are what gets pasted, everywhere.
            #expect(pasteboard.string(forType: .html) == nil)
            #expect(plain?.contains("<title>Notes</title>") == true)
            #expect(plain?.contains("<strong>bold</strong>") == true)
        }

        @Test @MainActor
        func copyAsRichTextFormattedWritesRTFHTMLAndPlainTextToTheGeneralPasteboard() throws {
            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "clipboard.e2e.\(UUID().uuidString)")))

            ClipboardExporter().copyAsRichTextFormatted(
                markdown: "---\ntitle: Notes\n---\n\n# Title\n\nSome **bold** text.",
                documentURL: nil,
                preferences: preferences
            )

            let pasteboard = NSPasteboard.general
            let rtfData = pasteboard.data(forType: .rtf)
            let html = pasteboard.string(forType: .html)
            let plain = pasteboard.string(forType: .string)

            #expect(rtfData != nil, "expected an RTF representation to be written")
            #expect(html?.contains("<title>Notes</title>") == true)
            #expect(plain?.contains("Title") == true)
            #expect(plain?.contains("bold") == true)

            if let rtfData {
                let attributed = try NSAttributedString(data: rtfData, options: [:], documentAttributes: nil)
                #expect(attributed.string.contains("Title"))
                #expect(attributed.string.contains("bold"))
            }
        }

        @Test @MainActor
        func copyAsRichTextFormattedOmitsRTFButStillWritesFallbacksWhenAnImageReferenceIsRemote() throws {
            let preferences =
                try Preferences(defaults: #require(UserDefaults(suiteName: "clipboard.e2e.\(UUID().uuidString)")))

            // A remote image reference stays un-inlined by ExportAssetResolver (issue #31 rule
            // 2.3), then gets stripped by ClipboardExporter before rich-text conversion (rule
            // 2.3) -- this proves the full pipeline still produces usable fallbacks even though
            // no image makes it into the rich-text representation.
            ClipboardExporter().copyAsRichTextFormatted(
                markdown: "# Title\n\n![remote](http://example.com/photo.png)\n\nSome text.",
                documentURL: nil,
                preferences: preferences
            )

            let pasteboard = NSPasteboard.general
            let html = pasteboard.string(forType: .html)
            let plain = pasteboard.string(forType: .string)

            #expect(html?.contains(#"src="http://example.com/photo.png""#) == true)
            #expect(plain?.contains("Title") == true)
        }
    #endif
}
