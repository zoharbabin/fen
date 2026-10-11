@testable import FenCore
import Foundation
import Testing

@Suite("Ask: prompt, citations and answer check (issue #141)")
struct AskAnswerTests {
    private func passage(_ index: Int, text: String = "Body") -> Passage {
        let heading = index.isMultiple(of: 2) ? "Part" : ""
        return Passage(
            workspaceID: UUID(),
            workspaceName: "Notes",
            relativePath: "doc\(index).md",
            heading: heading,
            startLine: index * 10,
            text: text
        )
    }

    @Test("a cited answer lists each passage once, in the order cited")
    func cited() {
        let reading = AnswerReading.read("We charge per seat [2]. The fee is monthly [1][2].", passageCount: 3)
        #expect(reading.cited == [2, 1])
        #expect(reading.invalid.isEmpty)
        #expect(reading.uncited == 0)
        #expect(!reading.isNotFound)
    }

    @Test("a list of numbers in one bracket counts as separate citations")
    func listedNumbers() {
        #expect(AnswerReading.read("Both teams agreed on the plan [1, 3].", passageCount: 3).cited == [1, 3])
    }

    @Test("a number with no passage is invalid and never becomes a link")
    func invalidNumber() {
        let answer = "The launch is in May [4]. It also needs a budget [1]."
        let reading = AnswerReading.read(answer, passageCount: 2)
        #expect(reading.invalid == [4])
        #expect(reading.cited == [1])
        #expect(reading.uncited == 0)
        let linked = AnswerReading.linked(answer, passageCount: 2)
        let links = linked.runs.compactMap(\.link)
        #expect(links == [URL(string: "fen-passage://1")])
    }

    @Test("a statement with no citation is counted, short lines are not")
    func uncited() {
        let answer = "Here you go:\nThe price is twelve dollars per seat.\nIt renews each month [1]."
        let reading = AnswerReading.read(answer, passageCount: 1)
        #expect(reading.uncited == 1)
    }

    @Test("the exact not-found reply is recognised, with or without the full stop")
    func notFound() {
        #expect(AnswerReading.read("Not found in the selected workspaces.", passageCount: 2).isNotFound)
        #expect(AnswerReading.read("  not found in the selected workspaces", passageCount: 2).isNotFound)
        #expect(!AnswerReading.read("The notes say it was not found in the repo [1].", passageCount: 2).isNotFound)
    }

    @Test("passages are numbered from 1 and carry the workspace and path")
    func context() {
        let items = AskPrompt.context(for: [passage(1), passage(2)])
        #expect(items.map(\.label) == ["[1] Notes/doc1.md", "[2] Notes/doc2.md > Part"])
    }

    @Test("the prompt asks for citations and gives the exact not-found reply")
    func prompt() {
        let text = AskPrompt.prompt(question: "What did we decide?")
        #expect(text.contains(AskPrompt.notFound))
        #expect(text.contains("[1]"))
        #expect(text.hasSuffix("Question: What did we decide?"))
    }

    @Test("passages are cut at the budget, and the best one always stays")
    func budget() {
        let big = String(repeating: "x", count: 4000)
        let kept = AskPrompt.fitting([passage(1, text: big), passage(2, text: big), passage(3, text: big)])
        #expect(kept.map(\.relativePath) == ["doc1.md"])
        let huge = String(repeating: "x", count: 9000)
        #expect(AskPrompt.fitting([passage(1, text: huge)]).count == 1)
    }

    @Test("a passage knows the lines it covers")
    func lines() {
        #expect(passage(1, text: "a\nb\nc").endLine == 12)
        #expect(passage(1, text: "a\nb\nc").lineRange == "lines 10 to 12")
        #expect(passage(1, text: "a").lineRange == "line 10")
    }
}

@MainActor
@Suite("Document jumps (issue #141)")
struct DocumentJumpTests {
    @Test("a request is taken once, by the file it names")
    func takenOnce() throws {
        let folder = try TempFolder("jump")
        defer { folder.cleanUp() }
        let url = try folder.write("a.md")
        let other = try folder.write("b.md")
        let jumps = DocumentJumps()
        jumps.request(line: 12, in: url)
        #expect(jumps.revision == 1)
        #expect(jumps.take(for: other) == nil)
        #expect(jumps.take(for: url) == 12)
        #expect(jumps.take(for: url) == nil)
    }

    @Test("a path spelled through a symlink finds the same request")
    func throughSymlink() throws {
        let folder = try TempFolder("jump-link")
        defer { folder.cleanUp() }
        let url = try folder.write("real/a.md")
        let link = folder.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: folder.root.appendingPathComponent("real")
        )
        let jumps = DocumentJumps()
        jumps.request(line: 3, in: link.appendingPathComponent("a.md"))
        #expect(jumps.take(for: url) == 3)
    }

    @Test("a line below 1 becomes line 1")
    func clamped() throws {
        let folder = try TempFolder("jump-clamp")
        defer { folder.cleanUp() }
        let url = try folder.write("a.md")
        let jumps = DocumentJumps()
        jumps.request(line: -4, in: url)
        #expect(jumps.take(for: url) == 1)
    }
}
