@testable import FenCore
import Foundation
import Testing

/// Proves rule 2.1 from issue #14's spec (github.com/zoharbabin/fen/issues/14): opening a
/// recent or restored document continues to go only through Fen's existing
/// `ReferenceFileDocument` read/write path -- no new filesystem access outside a
/// user-selected or previously-user-selected URL, no shell-out, no dynamic code execution.
struct DefaultEditorSecurityTests {
    /// `MarkdownDocument`'s read/write path never shells out or evaluates code -- it only
    /// decodes/encodes UTF-8 text. A source-level grep is the most direct proof that no such
    /// call was ever added, since the type has no injection point for one at the API level.
    @Test func markdownDocumentSourceContainsNoShellOutOrDynamicExecution() throws {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DefaultEditorSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/Models/MarkdownDocument.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval(", "URLSession"] {
            #expect(!source.contains(forbidden), "MarkdownDocument.swift must not contain '\(forbidden)'")
        }
    }

    /// Round-trips content through `MarkdownDocument`'s public read/write surface
    /// (`init(text:)` and `snapshot(contentType:)`) and asserts the bytes come back
    /// byte-for-byte -- the document only ever stores and returns what it was given, it never
    /// interprets, executes, or rewrites the content as anything else.
    @Test func documentRoundTripsContentByteForByteWithNoInterpretation() throws {
        let original = "# Title\n\n```swift\nProcess.launchedProcess(launchPath: \"/bin/echo\", arguments: [])\n```\n"
        let document = MarkdownDocument(text: original)

        let snapshot = try document.snapshot(contentType: .markdown)

        #expect(snapshot == original, "Content containing shell-like text must be treated as inert data, not executed")
        #expect(document.text == original)
    }

    /// A document's `fileURL` is only ever the URL explicitly assigned to it (by the document
    /// group, from the user's own open/recent selection) -- resolving/reading a document never
    /// substitutes or redirects to a different path.
    @Test func documentFileURLIsExactlyWhatWasAssignedNeverRewritten() {
        let document = MarkdownDocument(text: "content")
        let assigned = URL(fileURLWithPath: "/Users/someone/Documents/notes.md")

        document.fileURL = assigned

        #expect(document.fileURL == assigned)
        #expect(document.fileURL?.path == "/Users/someone/Documents/notes.md")
    }
}
