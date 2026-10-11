@testable import FenCore
import Foundation
import Testing

@Suite("Properties panel (issue #7)")
struct PropertiesSnapshotTests {
    private let schema = SchemaStarters.defaultSchema
    private let doc = "---\ntitle: Ship it  # keep\ntype: Task\nstatus: todo\n---\n# Body\n\nstatus: todo\n"

    private func field(_ name: String, in type: String = "Task") throws -> SchemaField {
        try #require(schema.type(named: type)?.field(named: name))
    }

    @Test("a known type shows its fields with the document's values")
    func rowsForKnownType() {
        let snapshot = PropertiesSnapshot(text: doc, schema: schema)
        #expect(snapshot.typeName == "Task")
        #expect(snapshot.rows.map(\.field.name) == ["status", "due", "priority"])
        #expect(snapshot.rows.map(\.value) == ["todo", "", ""])
        #expect(snapshot.isRelevant)
    }

    @Test("hidden fields are not shown but stay in the file")
    func hiddenFields() throws {
        var hidden = schema
        let index = try #require(hidden.types.firstIndex { $0.name == "Task" })
        hidden.types[index].fields[0].hidden = true
        let snapshot = PropertiesSnapshot(text: doc, schema: hidden)
        #expect(snapshot.rows.map(\.field.name) == ["due", "priority"])
        #expect(try snapshot.setting("2026-01-02", for: field("due")).contains("status: todo"))
    }

    @Test("an unknown type, no type, and no front matter all open normally with no panel")
    func unknownTypes() {
        for text in ["---\ntype: Gizmo\nx: 1\n---\nBody\n", "---\ntitle: T\n---\nBody\n", "Just text\n", ""] {
            let snapshot = PropertiesSnapshot(text: text, schema: schema)
            #expect(snapshot.type == nil)
            #expect(snapshot.rows.isEmpty)
            #expect(!snapshot.isRelevant)
        }
    }

    @Test("a document with only a typo still gets the panel, for the hint")
    func typoShowsPanel() {
        let snapshot = PropertiesSnapshot(text: "---\ntype: Tsak\n---\n", schema: schema)
        #expect(snapshot.type == nil)
        #expect(snapshot.hints.map(\.fix) == [.setType(to: "Task")])
        #expect(snapshot.isRelevant)
    }

    @Test("setting a value changes one line and nothing else, including the body")
    func settingKeepsBytes() throws {
        let snapshot = PropertiesSnapshot(text: doc, schema: schema)
        let done = try snapshot.setting("done", for: field("status"))
        #expect(done == doc.replacingOccurrences(of: "status: todo\n---", with: "status: done\n---"))
        let due = try snapshot.setting("2026-07-01", for: field("due"))
        #expect(due == doc.replacingOccurrences(of: "status: todo\n---", with: "status: todo\ndue: 2026-07-01\n---"))
        #expect(PropertiesSnapshot(text: due, schema: schema).rows[1].value == "2026-07-01")
    }

    @Test("clearing a field removes its line, and bad input throws and changes nothing")
    func clearAndInvalid() throws {
        let snapshot = PropertiesSnapshot(text: doc, schema: schema)
        let cleared = try snapshot.setting("", for: field("status"))
        #expect(cleared == doc.replacingOccurrences(of: "status: todo\n---", with: "---"))
        #expect(throws: PropertyError.notADate) { try snapshot.setting("soon", for: field("due")) }
    }

    @Test("a document with no front matter gets one when you set a value")
    func createsFrontMatter() throws {
        let snapshot = PropertiesSnapshot(text: "# Plain\n", schema: schema)
        let result = try snapshot.setting("x", for: field("status"))
        #expect(result == "---\nstatus: x\n---\n# Plain\n")
    }

    @Test("a list stored as a block is shown and not edited")
    func blockListIsReadOnly() throws {
        let text = "---\ntype: Meeting\nattendees:\n  - Ann\n  - Bo\n---\n"
        let snapshot = PropertiesSnapshot(text: text, schema: schema)
        let row = try #require(snapshot.rows.first { $0.field.name == "attendees" })
        #expect(row.value == "Ann, Bo")
        #expect(throws: FrontMatterError.complexExistingValue) {
            try snapshot.setting("Cy", for: row.field)
        }
    }

    @Test("a missing required field is flagged")
    func requiredFlag() {
        let snapshot = PropertiesSnapshot(text: "---\ntype: Meeting\n---\n", schema: schema)
        #expect(snapshot.rows.first { $0.field.name == "date" }?.isMissingRequired == true)
    }

    @Test("applying a hint fix edits only the typo")
    func applyFix() throws {
        let text = "---\ntype: Tsak\nstatus: x\n---\nBody\n"
        let snapshot = PropertiesSnapshot(text: text, schema: schema)
        let fix = try #require(snapshot.hints.first?.fix)
        #expect(try snapshot.applying(fix) == text.replacingOccurrences(of: "Tsak", with: "Task"))
    }
}

@Suite("Minimal editor edit (issue #7)")
struct MinimalEditTests {
    private func apply(_ edit: EditorInsertion, to text: String) -> String? {
        guard edit.applies(to: text) else { return nil }
        return (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
    }

    @Test("equal texts need no edit")
    func equal() {
        #expect(EditorInsertion.minimalEdit(from: "same", to: "same") == nil)
    }

    @Test("the edit covers only what changed")
    func small() throws {
        let edit = try #require(EditorInsertion.minimalEdit(from: "a: 1\nb: 2\n", to: "a: 1\nb: 3\n"))
        #expect(edit.expected == "2")
        #expect(edit.text == "3")
        #expect(edit.range == NSRange(location: 8, length: 1))
    }

    @Test("random edits, with emoji and CRLF, always turn old into new")
    func randomized() {
        var generator = SeededGenerator(seed: 99)
        let pieces = ["a", "b", "é", "👩‍👩‍👧", "😀", "\r\n", "\n", " ", ":", "ab"]
        func make(_ generator: inout SeededGenerator) -> String {
            (0 ..< Int.random(in: 0 ... 12, using: &generator))
                .map { _ in pieces[Int.random(in: 0 ..< pieces.count, using: &generator)] }
                .joined()
        }
        for _ in 0 ..< 500 {
            let old = make(&generator)
            let new = make(&generator)
            guard let edit = EditorInsertion.minimalEdit(from: old, to: new) else {
                #expect(old == new)
                continue
            }
            #expect(apply(edit, to: old) == new, "\(old.debugDescription) -> \(new.debugDescription)")
        }
    }
}

@Suite("Date fields hold a day (issue #7)")
struct DayFieldTests {
    @Test(
        "a day survives the picker in any time zone",
        arguments: ["UTC", "Asia/Tokyo", "America/Los_Angeles", "Pacific/Kiritimati"]
    )
    func roundTrip(zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        for text in ["2026-03-31", "2024-02-29", "2026-12-31", "2026-01-01"] {
            let date = try #require(DocumentProperties.day(from: text, calendar: calendar))
            #expect(DocumentProperties.text(forDay: date, calendar: calendar) == text)
        }
        #expect(DocumentProperties.day(from: "2026-02-30", calendar: calendar) == nil)
        #expect(DocumentProperties.day(from: "tomorrow", calendar: calendar) == nil)
    }
}
