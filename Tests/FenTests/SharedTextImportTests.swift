@testable import FenCore
import Foundation
import Testing

/// Issue #43: shared text (not a file) becomes a new document.
struct SharedTextImportTests {
    @Test
    func plainTextBecomesADocumentThatEndsWithOneNewline() throws {
        #expect(try SharedTextImport.text(from: "Hello\n\n\n") == "Hello\n")
        #expect(try SharedTextImport.document(from: "# Title\n\nBody")?.text == "# Title\n\nBody\n")
    }

    @Test
    func nothingToImportGivesNil() throws {
        #expect(try SharedTextImport.text(from: nil) == nil)
        #expect(try SharedTextImport.text(from: "") == nil)
        #expect(try SharedTextImport.text(from: " \n\t \r\n\u{00A0}\u{2028}") == nil)
        #expect(try SharedTextImport.text(from: "\u{0}\u{7}\u{FEFF}") == nil)
        #expect(try SharedTextImport.document(from: "  \n") == nil)
    }

    @Test
    func theTextIsKeptAsCopiedWithNoFrontMatterOrHeadingAdded() throws {
        let text = try #require(try SharedTextImport.text(from: "plain words"))
        #expect(text == "plain words\n")
        #expect(!text.hasPrefix("---") && !text.hasPrefix("#"))
    }

    @Test
    func existingFrontMatterIsNotTouched() throws {
        #expect(try SharedTextImport.text(from: "---\ntitle: A\n---\nBody") == "---\ntitle: A\n---\nBody\n")
    }

    @Test
    func lineEndingsBecomeNewlines() throws {
        #expect(try SharedTextImport.text(from: "a\r\nb\rc\u{2028}d\u{2029}e\nf") == "a\nb\nc\nd\ne\nf\n")
        // Two CRs are two breaks, not one.
        #expect(try SharedTextImport.text(from: "a\r\rb") == "a\n\nb\n")
    }

    @Test
    func controlCharactersAreRemovedButTabsStay() throws {
        #expect(try SharedTextImport.text(from: "a\u{0}b\u{7}c\u{1B}d\u{7F}e\u{85}f\tg") == "abcdef\tg\n")
    }

    @Test
    func byteOrderMarksAreDropped() throws {
        #expect(try SharedTextImport.text(from: "\u{FEFF}# Title") == "# Title\n")
        #expect(try SharedTextImport.text(from: "a\u{FEFF}b") == "ab\n")
    }

    @Test
    func leadingBlankLinesGoButFirstLineIndentStays() throws {
        #expect(try SharedTextImport.text(from: "\n \n\t\n    code()\n  \n") == "    code()\n")
    }

    @Test
    func unicodeSurvivesIntact() throws {
        let text = "Caf\u{E9} \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} \u{65E5}\u{672C}\u{8A9E} e\u{301}"
        #expect(try SharedTextImport.text(from: text) == text + "\n")
    }

    @Test
    func textJustUnderTheLimitImportsAndOverItIsRefusedNotCut() throws {
        let fits = String(repeating: "a", count: SharedTextImport.maxBytes - 1)
        #expect(try SharedTextImport.text(from: fits) == fits + "\n")
        let tooBig = String(repeating: "a", count: SharedTextImport.maxBytes)
        #expect(throws: SharedTextImport.Failure.tooLarge) { try SharedTextImport.text(from: tooBig) }
        #expect(throws: SharedTextImport.Failure.tooLarge) { try SharedTextImport.document(from: tooBig) }
    }

    @Test
    func theLimitCountsBytesNotCharacters() {
        // Each of these is 3 bytes in UTF-8, so the text is over the limit in bytes only.
        let wide = String(repeating: "\u{65E5}", count: SharedTextImport.maxBytes / 3 + 1)
        #expect(wide.count < SharedTextImport.maxBytes)
        #expect(throws: SharedTextImport.Failure.tooLarge) { try SharedTextImport.text(from: wide) }
    }

    @Test
    func aHugePasteIsRefusedWithoutCleaningIt() {
        let huge = String(repeating: "x", count: SharedTextImport.maxBytes * 4 + 1)
        #expect(throws: SharedTextImport.Failure.tooLarge) { try SharedTextImport.text(from: huge) }
    }

    @Test
    func controlCharactersDoNotCountTowardTheLimit() throws {
        // Over the limit raw, under it once the NULs are gone.
        let padded = String(repeating: "\u{0}", count: 1000)
            + String(repeating: "a", count: SharedTextImport.maxBytes - 10)
        #expect(try SharedTextImport.text(from: padded) != nil)
    }

    @Test
    func theErrorHasAReadableMessage() {
        #expect(SharedTextImport.Failure.tooLarge.localizedDescription.contains("too large"))
    }
}
