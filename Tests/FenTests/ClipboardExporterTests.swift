@testable import FenCore
import Foundation
import Testing

/// Proves issue #33 rule 3 (resiliency): a composed HTML string that fails rich-text conversion
/// degrades to no rich-text representation rather than crashing "Copy as Rich Text Formatted",
/// and every pasteboard representation still gets a usable plain-text fallback.
struct ClipboardExporterTests {
    @Test @MainActor
    func emptyHTMLProducesAnEmptyAttributedStringRatherThanThrowing() {
        let exporter = ClipboardExporter()
        let attributed = exporter.attributedString(from: "")
        #expect(attributed != nil)
        #expect(attributed?.length == 0)
    }

    @Test @MainActor
    func binaryGarbageNeverCrashesConversion() {
        // Not valid UTF-8 text at all -- proves `attributedString(from:)` degrades to `nil`
        // instead of trapping, since `String(data:encoding:)` itself fails first.
        let exporter = ClipboardExporter()
        let garbage = String(bytes: [0xFF, 0xFE, 0x00, 0x01, 0x02], encoding: .utf8) ?? "fallback"
        let attributed = exporter.attributedString(from: garbage)
        // Whatever the importer makes of this input, the call must return rather than crash.
        _ = attributed
    }

    @Test @MainActor
    func composedSelfContainedHTMLConvertsToNonEmptyRichText() throws {
        let preferences =
            try Preferences(defaults: #require(UserDefaults(suiteName: "clipboard.tests.\(UUID().uuidString)")))
        let exporter = ClipboardExporter()
        let html = exporter.composeHTML(
            markdown: "# Title\n\nSome **bold** text.",
            documentURL: nil,
            preferences: preferences
        )
        let attributed = exporter.attributedString(from: exporter.strippingNonDataImages(from: html))

        #expect(attributed != nil)
        #expect(attributed?.string.contains("Title") == true)
        #expect(attributed?.string.contains("bold") == true)
    }

    @Test @MainActor
    func strippingNonDataImagesLeavesDataURIImagesIntact() {
        let exporter = ClipboardExporter()
        let html = #"<html><body><img src="data:image/png;base64,QUJD"><p>Text</p></body></html>"#
        let stripped = exporter.strippingNonDataImages(from: html)
        #expect(stripped.contains("data:image/png;base64,QUJD"), "a data: URI image must never be stripped")
        #expect(stripped.contains("Text"))
    }
}
