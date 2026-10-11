@testable import FenCore
import Foundation
import Testing

@Suite("Editor selection for related documents (issue #8)")
struct EditorSelectionTests {
    private let document = """
    # Title

    First paragraph is short.

    This is the paragraph I am writing now,
    and it runs over two lines of text.

    Last one.
    """

    private func range(of text: String) -> NSRange {
        (document as NSString).range(of: text)
    }

    @Test("a selection is the selected text, and short ones are ignored")
    func selection() {
        let words = range(of: "the paragraph I am writing")
        let picked = EditorSelection.make(in: document, selected: words, typing: false)
        #expect(picked?.kind == .selection)
        #expect(picked?.text == "the paragraph I am writing")
        #expect(picked?.range == words)
        #expect(EditorSelection.make(in: document, selected: range(of: "short"), typing: false) == nil)
    }

    @Test("a caret gives its paragraph only while you type, and offers the end of it")
    func paragraph() throws {
        let caret = NSRange(location: range(of: "runs over").location, length: 0)
        #expect(EditorSelection.make(in: document, selected: caret, typing: false) == nil)
        let found = try #require(EditorSelection.make(in: document, selected: caret, typing: true))
        #expect(found.kind == .paragraph)
        #expect(found.text == "This is the paragraph I am writing now,\nand it runs over two lines of text.")
        let paragraph = range(of: found.text)
        #expect(found.range == NSRange(location: NSMaxRange(paragraph), length: 0))
    }

    @Test("a short paragraph, a heading, and a blank line give nothing")
    func nothing() {
        func at(_ text: String) -> EditorSelection? {
            EditorSelection.make(
                in: document,
                selected: NSRange(location: range(of: text).location, length: 0),
                typing: true
            )
        }
        #expect(at("First paragraph") == nil)
        #expect(at("# Title") == nil)
        #expect(EditorSelection.make(in: "a\n\nb", selected: NSRange(location: 2, length: 0), typing: true) == nil)
        #expect(EditorSelection.make(in: "", selected: NSRange(location: 0, length: 0), typing: true) == nil)
        #expect(EditorSelection.make(in: "short", selected: NSRange(location: 99, length: 0), typing: true) == nil)
    }

    @Test("a huge selection, such as select all, is ignored")
    func huge() {
        let big = String(repeating: "word ", count: 2000)
        #expect(EditorSelection
            .make(in: big, selected: NSRange(location: 0, length: big.utf16.count), typing: false) == nil)
    }

    @Test("a heading section runs to the next heading of the same or a higher level")
    func section() {
        let text = """
        # Guide
        Intro text that is long enough.
        ## Setup
        Install the tool and run it once.
        ### Detail
        Deeper notes live here for you.
        ```
        # not a heading
        ```
        ## Next
        Other text that should be left out.
        """
        let setup = EditorSelection.section(ofHeading: "Setup", level: 2, in: text)
        #expect(setup?.contains("Install the tool") == true)
        #expect(setup?.contains("Deeper notes") == true)
        #expect(setup?.contains("not a heading") == true)
        #expect(setup?.contains("Other text") == false)
        #expect(EditorSelection.section(ofHeading: "Missing", level: 2, in: text) == nil)
        #expect(EditorSelection.section(ofHeading: "Setup", level: 3, in: text) == nil)
    }

    @Test("a heading with emphasis still matches its rendered text")
    func sectionWithMarkup() {
        let text = "## **Bold** `plan`\nThe plan has enough words in it.\n"
        #expect(EditorSelection.section(ofHeading: "Bold plan", level: 2, in: text) != nil)
    }

    @Test("an insertion applies only where the expected text still sits")
    func insertion() {
        let text = "hello brave world"
        let edit = EditorInsertion(range: NSRange(location: 6, length: 5), expected: "brave", text: "[brave](a.md)")
        #expect(edit.applies(to: text))
        #expect(!edit.applies(to: "hello cruel world"))
        #expect(!edit.applies(to: "hello"))
        #expect(EditorInsertion(range: NSRange(location: 5, length: 0), expected: "", text: "x").applies(to: text))
        #expect(EditorInsertion(range: NSRange(location: 6, length: 5), expected: "brave", text: "x").id != edit.id)
    }
}
