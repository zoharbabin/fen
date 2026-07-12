@testable import FenCore
import Testing

/// Harness gate 3 for issue #12: constructs 2+ `DocumentOutline` instances in one process and
/// proves no state leaks between them, per rule 1.1/1.2 (per-instance state only, no
/// module-level mutable store).
struct DocumentOutlineIsolationTests {
    @Test func twoInstancesOverDifferentDocumentsDoNotShareHeadingsOrFoldState() {
        let docA = DocumentOutline()
        let docB = DocumentOutline()

        docA.update(headings: [Heading(level: 1, text: "A1", slug: "a1"), Heading(level: 1, text: "A2", slug: "a2")])
        docB.update(headings: [Heading(level: 1, text: "B1", slug: "b1")])

        #expect(docA.headings.map(\.slug) == ["a1", "a2"])
        #expect(docB.headings.map(\.slug) == ["b1"])

        docA.toggleCollapse(slug: "a1")
        #expect(docA.isCollapsed(slug: "a1"))
        #expect(!docB.isCollapsed(slug: "a1"))
        #expect(docB.headings.map(\.slug) == ["b1"], "docB's heading list must be unaffected by docA's mutation")
    }

    @Test func twoInstancesOverIdenticalDocumentTextRemainIndependent() {
        let sharedHeadings = [Heading(level: 2, text: "Same Title", slug: "same-title")]
        let windowOne = DocumentOutline()
        let windowTwo = DocumentOutline()

        windowOne.update(headings: sharedHeadings)
        windowTwo.update(headings: sharedHeadings)

        windowOne.toggleCollapse(slug: "same-title")

        #expect(windowOne.isCollapsed(slug: "same-title"))
        #expect(
            !windowTwo.isCollapsed(slug: "same-title"),
            "Folding a heading in one window must not fold it in another window open on the same document"
        )
    }

    @Test func threeConcurrentInstancesEachKeepIndependentState() async {
        let outlines = (0 ..< 3).map { _ in DocumentOutline() }
        await withTaskGroup(of: Void.self) { group in
            for (index, outline) in outlines.enumerated() {
                group.addTask { @MainActor in
                    outline.update(headings: [Heading(level: 1, text: "H\(index)", slug: "h\(index)")])
                    outline.toggleCollapse(slug: "h\(index)")
                }
            }
        }

        for (index, outline) in outlines.enumerated() {
            #expect(outline.headings.map(\.slug) == ["h\(index)"])
            #expect(outline.isCollapsed(slug: "h\(index)"))
            for otherIndex in 0 ..< 3 where otherIndex != index {
                #expect(!outline.isCollapsed(slug: "h\(otherIndex)"))
            }
        }
    }
}
