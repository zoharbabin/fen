@testable import FenCore
import Foundation
import Testing

/// `MarkdownDocument.title` runs on every toolbar render for an unsaved note (the share button
/// reads it), so it must not scan the whole text.
@MainActor
struct DocumentTitleTests {
    @Test
    func theTitleIsTheFirstHeadingAfterBlankLines() {
        #expect(MarkdownDocument(text: "\n  \n# Plan\n\nBody").title == "Plan")
        #expect(MarkdownDocument(text: "# Plan").title == "Plan")
        #expect(MarkdownDocument(text: "# Plan\r\n\r\nBody").title == "Plan")
    }

    @Test
    func noTitleWhenTextComesBeforeAnyHeading() {
        #expect(MarkdownDocument(text: "Intro\n# Later").title == nil)
        #expect(MarkdownDocument(text: "").title == nil)
    }

    @Test
    func aLargeNoteWithoutAHeadingIsNotScanned() {
        let document = MarkdownDocument(text: "Intro\n" + String(repeating: "line of text\n", count: 1_000_000))
        let start = ContinuousClock.now
        for _ in 0 ..< 10 {
            _ = document.title
        }
        #expect(ContinuousClock.now - start < .milliseconds(100))
    }
}
