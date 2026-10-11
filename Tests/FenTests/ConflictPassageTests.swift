@testable import FenCore
import Foundation
import Testing

@Suite("Passages of a note (issue #94)")
struct ConflictPassageTests {
    private let note = """
    ---
    title: Plan
    ---

    # Plan

    We ship the release every two weeks on Thursday.

    - The review takes three days for each change.
    - Short.

    ```swift
    let hidden = "This code block must never be checked as a claim."
    ```

    ## Notes

    The team lead signs off on every release before it goes out.
    It never ships on a Friday afternoon.
    """

    @Test("Paragraphs and list items are passages. Front matter, headings, fences and fragments are not")
    func splits() {
        let passages = ConflictPassage.split(note)
        #expect(passages.map(\.text) == [
            "We ship the release every two weeks on Thursday.",
            "- The review takes three days for each change.",
            "The team lead signs off on every release before it goes out.\nIt never ships on a Friday afternoon.",
        ])
        #expect(passages.map(\.startLine) == [7, 9, 18])
    }

    @Test("The hash ignores how the lines are wrapped")
    func hashIgnoresWrapping() {
        let one = ConflictPassage.hash(of: "We ship the release every two weeks.")
        let two = ConflictPassage.hash(of: "We ship  the release\nevery two weeks.")
        #expect(one == two)
        #expect(one != ConflictPassage.hash(of: "We ship the release every three weeks."))
    }

    @Test("A passage is found again by its hash after text moves above it")
    func findsAfterMove() throws {
        let hash = try #require(ConflictPassage.split(note).first).hash
        let moved = "A new first paragraph that is long enough to count.\n\n" + note
        let found = try #require(ConflictPassage.find(hash: hash, in: moved))
        #expect(found.startLine > 7)
        #expect(ConflictPassage.find(hash: hash, in: "Something else entirely, long enough to count.") == nil)
    }

    @Test("A heading-only block does not swallow the paragraph under it")
    func headingThenParagraph() {
        let passages = ConflictPassage.split("# Title\nThe paragraph right under the heading is long enough.\n")
        #expect(passages.map(\.text) == ["The paragraph right under the heading is long enough."])
    }

    @Test("Notes without a passage give none")
    func empty() {
        #expect(ConflictPassage.split("").isEmpty)
        #expect(ConflictPassage.split("# Only a heading\n").isEmpty)
    }
}

@Suite("Contradiction marks (issue #94)")
struct ConflictSignalsTests {
    private func score(_ changed: String, _ other: String) -> ConflictSignals {
        ConflictSignals.compare(changed: changed, other: other)
    }

    @Test("A number that differs is a mark")
    func numbers() {
        let result = score("The review takes 5 days.", "The review takes 3 days.")
        #expect(result.score >= 0.25)
        #expect(result.reasons.contains { $0.contains("numbers differ") })
    }

    @Test("The same numbers are not a mark")
    func sameNumbers() {
        #expect(score("The review takes 3 days.", "A review is done in 3 days.").score == 0)
    }

    @Test("One side negating is a mark, both negating is not")
    func negation() {
        #expect(score("We do not sign builds.", "We sign every build.").score >= 0.25)
        #expect(score("The review is never skipped, ever.", "We do not skip the review at all.").score == 0)
    }

    @Test("Opposite words are a mark")
    func opposites() {
        #expect(score("Sync is enabled for all users.", "Sync is disabled for all users.").score >= 0.25)
    }

    @Test("A cue of change counts only in the changed passage")
    func changeCue() {
        let inChanged = score("We now use Postgres instead of MySQL.", "We store data in MySQL.")
        let inOther = score("We store data in MySQL.", "We now use Postgres instead of MySQL.")
        #expect(inChanged.score > inOther.score)
    }

    @Test("Unrelated agreeing text shows nothing")
    func nothing() {
        let result = score("The office opens at the usual hour.", "Visitors sign in at the front desk.")
        #expect(result == .none)
    }

    @Test("The score never goes above 1")
    func capped() {
        let result = score(
            "We no longer allow the old flow. It is disabled, not 5 days but 9, and we now use the new one.",
            "We allow the old flow and it is enabled. It takes 5 days."
        )
        #expect(result.score <= 1)
    }
}
