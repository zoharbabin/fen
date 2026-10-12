@testable import FenCore
import Foundation
import Testing

@Suite("Schema hints and properties (issue #7)")
struct SchemaHintsTests {
    private let schema = SchemaStarters.defaultSchema

    private func front(_ yaml: String) -> [String: Any]? {
        MarkdownRenderer().peekFrontMatter("---\n\(yaml)\n---\nBody\n")
    }

    @Test("a swap counts as one edit")
    func distance() {
        #expect(SchemaHints.editDistance("tpye", "type") == 1)
        #expect(SchemaHints.editDistance("kitten", "sitting") == 3)
        #expect(SchemaHints.editDistance("", "abc") == 3)
        #expect(SchemaHints.editDistance("same", "same") == 0)
    }

    @Test("a near-miss type value gets a hint that suggests the real one")
    func nearMissType() {
        for typo in ["Meetng", "meeting", "Meting", "Mmeeting", "Metting"] {
            let hints = SchemaHints.hints(for: front("type: \(typo)"), in: schema)
            #expect(hints.map(\.fix) == [.setType(to: "Meeting")], "\(typo)")
        }
    }

    @Test("a misspelt field name and a misspelt type key get hints")
    func nearMissKeys() {
        let field = SchemaHints.hints(for: front("type: Task\nstatsu: done"), in: schema)
        #expect(field.map(\.fix) == [.renameKey(from: "statsu", to: "status")])
        let key = SchemaHints.hints(for: front("tpye: Task"), in: schema)
        #expect(key.map(\.fix) == [.renameKey(from: "tpye", to: "type")])
        let cased = SchemaHints.hints(for: front("Type: Task"), in: schema)
        #expect(cased.map(\.fix) == [.renameKey(from: "Type", to: "type")])
    }

    @Test("a correct document, an unknown type, and extra keys get no hint")
    func noFalsePositives() {
        let documents = [
            "type: Task\nstatus: done\ndue: 2026-01-01\ntitle: Ship it\ntags: [a, b]",
            "type: Gizmo\nwhatever: 1",
            "title: Just a note",
            "type: Person\nowner: me\nnotes: here",
            "type: Task\nstatus: done\nstatuses: many",
        ]
        for document in documents {
            #expect(SchemaHints.hints(for: front(document), in: schema).isEmpty, "\(document)")
        }
        #expect(SchemaHints.hints(for: nil, in: schema).isEmpty)
    }

    @Test("a key that is already a field is never renamed onto itself, and a taken field is not suggested")
    func takenFieldNotSuggested() {
        let hints = SchemaHints.hints(for: front("type: Task\nstatus: done\nstatsu: x"), in: schema)
        #expect(hints.isEmpty)
    }

    @Test("form text for every kind of value read from YAML")
    func textForValues() throws {
        let values = try #require(front("a: hi\nb: true\nc: 3\nd: 2.5\ne: 2026-03-31\nf: [x, 2]\ng:\n  k: v"))
        #expect(DocumentProperties.text(for: values["a"]) == "hi")
        #expect(DocumentProperties.text(for: values["b"]) == "true")
        #expect(DocumentProperties.text(for: values["c"]) == "3")
        #expect(DocumentProperties.text(for: values["d"]) == "2.5")
        #expect(DocumentProperties.text(for: values["e"]) == "2026-03-31")
        #expect(DocumentProperties.text(for: values["f"]) == "x, 2")
        #expect(DocumentProperties.text(for: nil).isEmpty)
        #expect(DocumentProperties.isEditable(values["f"]))
        #expect(!DocumentProperties.isEditable(values["g"]))
    }

    @Test("form input becomes one line of YAML, or is refused for the wrong kind")
    func yamlForInput() throws {
        func yaml(_ kind: FieldKind, _ input: String) throws -> String? {
            try DocumentProperties.yaml(for: SchemaField("f", kind), input: input)
        }
        #expect(try yaml(.text, "Hello: world") == "\"Hello: world\"")
        #expect(try yaml(.text, "  ") == nil)
        #expect(try yaml(.boolean, "Yes") == "true")
        #expect(try yaml(.number, "4.5") == "4.5")
        #expect(try yaml(.date, "2026-02-28") == "2026-02-28")
        #expect(try yaml(.list, "a, b c, \"d\"") == "[a, b c, \"\\\"d\\\"\"]")
        #expect(throws: PropertyError.notANumber) { try yaml(.number, "abc") }
        #expect(throws: PropertyError.notANumber) { try yaml(.number, "nan") }
        #expect(throws: PropertyError.notADate) { try yaml(.date, "2026-02-30") }
        #expect(throws: PropertyError.notADate) { try yaml(.date, "tomorrow") }
        #expect(throws: PropertyError.notABoolean) { try yaml(.boolean, "maybe") }
    }

    @Test("every value the form writes reads back as the same text")
    func writeThenRead() throws {
        let cases: [(FieldKind, String)] = [
            (.text, "A #1: thing"), (.text, "true"), (.text, "007"), (.boolean, "true"), (.number, "12"),
            (.date, "2024-02-29"), (.list, "x, y z, 3"), (.choice, "done"),
        ]
        for (kind, input) in cases {
            let line = try #require(try DocumentProperties.yaml(for: SchemaField("f", kind), input: input))
            let parsed = try #require(front("f: \(line)"))
            #expect(DocumentProperties.text(for: parsed["f"]) == input, "\(kind) \(input)")
        }
    }
}

@Suite("Front matter edits keep other bytes (issue #7)")
struct FrontMatterEditTests {
    private let text = "---\r\ntitle: \"Hi\"   # keep\r\ntype: Task\r\nstatus: todo\r\n---\r\n# Body\r\n"

    @Test("setRaw changes one line and no other byte")
    func setRawKeepsRest() throws {
        let result = try FrontMatterEditor.setRaw(key: "status", yaml: "done", in: text)
        #expect(result == text.replacingOccurrences(of: "status: todo", with: "status: done"))
        let added = try FrontMatterEditor.setRaw(key: "due", yaml: "2026-01-01", in: text)
        #expect(added == text.replacingOccurrences(of: "status: todo\r\n", with: "status: todo\r\ndue: 2026-01-01\r\n"))
    }

    @Test("renameKey keeps the value and the comment, and does nothing when the new name is taken")
    func rename() throws {
        let result = try FrontMatterEditor.renameKey(from: "title", to: "name", in: text)
        #expect(result == text.replacingOccurrences(of: "title:", with: "name:"))
        #expect(try FrontMatterEditor.renameKey(from: "title", to: "type", in: text) == text)
        #expect(try FrontMatterEditor.renameKey(from: "missing", to: "x", in: text) == text)
        #expect(throws: FrontMatterError.invalidKey) { try FrontMatterEditor.renameKey(
            from: "title",
            to: "a b",
            in: text
        ) }
    }

    @Test("removeKey drops one line, and refuses a block value")
    func remove() throws {
        let result = try FrontMatterEditor.removeKey("status", in: text)
        #expect(result == text.replacingOccurrences(of: "status: todo\r\n", with: ""))
        let block = "---\ntags:\n  - a\n  - b\n---\n"
        #expect(throws: FrontMatterError.complexExistingValue) { try FrontMatterEditor.removeKey("tags", in: block) }
        #expect(try FrontMatterEditor.removeKey("none", in: block) == block)
    }
}

@Suite("Front matter with Windows line endings (issue #7)")
struct CRLFFrontMatterTests {
    @Test("front matter in a CRLF file is read, so typed properties work there too")
    func crlf() {
        let front = MarkdownRenderer().peekFrontMatter("---\r\ntype: Task\r\ndue: 2026-05-05\r\n---\r\nBody\r\n")
        #expect(DocumentProperties.typeName(in: front) == "Task")
        #expect(DocumentProperties.text(for: front?["due"]) == "2026-05-05")
        let html = MarkdownRenderer().render("---\r\ntitle: T\r\n---\r\n# Hi\r\n").html
        #expect(!html.contains("title: T"))
    }
}
