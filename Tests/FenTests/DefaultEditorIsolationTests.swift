@testable import FenCore
import Foundation
import Testing

/// Harness gate 3 for issue #14 (github.com/zoharbabin/fen/issues/14): constructs 2+
/// `MarkdownDocument` instances in one process and proves no state leaks between them, per
/// rule 1.1 (any new state this feature adds is scoped per-window, never a module-level
/// mutable global beyond what AppKit's own `NSDocumentController.shared` already provides).
struct DefaultEditorIsolationTests {
    @Test func twoDocumentsKeepIndependentTextAndFileURL() {
        let docA = MarkdownDocument(text: "# Document A")
        let docB = MarkdownDocument(text: "# Document B")

        docA.fileURL = URL(fileURLWithPath: "/tmp/a.md")
        docB.fileURL = URL(fileURLWithPath: "/tmp/b.md")

        #expect(docA.text == "# Document A")
        #expect(docB.text == "# Document B")
        #expect(docA.fileURL?.path == "/tmp/a.md")
        #expect(docB.fileURL?.path == "/tmp/b.md")

        docA.text = "# Edited A"
        #expect(docA.text == "# Edited A")
        #expect(docB.text == "# Document B", "Mutating one document's text must not affect another instance's text")
        #expect(docB.fileURL?.path == "/tmp/b.md", "Mutating one document's fileURL must not affect another instance")
    }

    @Test func threeDocumentsEachKeepIndependentState() {
        let docs = (0 ..< 3).map { MarkdownDocument(text: "# Doc \($0)") }
        for (index, doc) in docs.enumerated() {
            doc.fileURL = URL(fileURLWithPath: "/tmp/doc\(index).md")
        }

        for (index, doc) in docs.enumerated() {
            #expect(doc.text == "# Doc \(index)")
            #expect(doc.fileURL?.path == "/tmp/doc\(index).md")
            for otherIndex in 0 ..< 3 where otherIndex != index {
                #expect(doc.fileURL?.path != "/tmp/doc\(otherIndex).md")
            }
        }
    }

    @Test func snapshotOfOneDocumentIsUnaffectedByConcurrentEditsToAnother() throws {
        let docA = MarkdownDocument(text: "Alpha content")
        let docB = MarkdownDocument(text: "Beta content")

        let snapshotA = try docA.snapshot(contentType: .markdown)
        docB.text = "Beta content, now mutated"
        let snapshotAAfterBMutated = try docA.snapshot(contentType: .markdown)

        #expect(
            snapshotA == snapshotAAfterBMutated,
            "Snapshotting document A must be unaffected by mutating document B"
        )
        #expect(!snapshotAAfterBMutated.contains("mutated"))
    }
}
