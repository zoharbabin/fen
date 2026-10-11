@testable import FenCore
import Foundation
import Testing

@Suite("Schema editing (issue #7)")
struct SchemaDraftTests {
    private let base = SchemaStarters.defaultSchema

    @Test("a draft turns back into the same schema")
    func roundTrip() {
        #expect(SchemaDraft(base).schema == base)
    }

    @Test("adding a type and a field gives unique names")
    func adding() {
        var draft = SchemaDraft(base)
        let first = draft.addType()
        draft.addType()
        draft.addField(toType: first)
        draft.addField(toType: first)
        let added = draft.schema.types.suffix(2).map(\.name)
        #expect(added == ["NewType", "NewType2"])
        #expect(draft.schema.types[base.types.count].fields.map(\.name) == ["new_field", "new_field2"])
        #expect(draft.problems.isEmpty)
    }

    @Test("removing a type or field removes only it")
    func removing() throws {
        var draft = SchemaDraft(base)
        let person = try #require(draft.types.first)
        let field = try #require(person.fields.first)
        draft.removeField(field.id, fromType: person.id)
        #expect(draft.schema.types[0].fields.count == person.fields.count - 1)
        draft.removeType(person.id)
        #expect(draft.schema.types.count == base.types.count - 1)
    }

    @Test("a starter pack adds only the types you don't have")
    func packs() throws {
        var draft = SchemaDraft(base)
        let sales = try #require(SchemaStarters.packs.first { $0.id == "sales" })
        draft.add(sales)
        draft.add(sales)
        #expect(draft.schema.types.suffix(2).map(\.name) == ["Deal", "Account"])
        #expect(draft.schema.types.count == base.types.count + 2)
        #expect(draft.problems.isEmpty)
        #expect(SchemaDiff(from: base, to: draft.schema).isBreaking == false)
    }

    @Test("problems explain what blocks a save, and the schema validator agrees")
    func problems() throws {
        var draft = SchemaDraft(base)
        draft.types[0].name = "bad name"
        draft.types[1].name = draft.types[2].name
        draft.types[3].fields[0].name = draft.types[3].fields[1].name
        draft.types[4].fields[0].kind = .choice
        draft.types[4].fields[0].valuesText = " , "
        #expect(draft.problems.count == 4)
        #expect(throws: SchemaError.self) { try draft.schema.validate() }
        draft = SchemaDraft(base)
        #expect(draft.problems.isEmpty)
    }

    @Test("choice values are trimmed and de-duplicated")
    func values() {
        var draft = SchemaDraft(base)
        draft.types[0].fields[0].kind = .choice
        draft.types[0].fields[0].valuesText = "a,  b ,a,, c"
        #expect(draft.schema.types[0].fields[0].values == ["a", "b", "c"])
    }

    @Test("every change has a plain sentence")
    func summaries() {
        var changed = base
        changed.types.removeLast()
        changed.types[0].fields[0].kind = .number
        changed.types.append(DocumentType("New", description: ""))
        let diff = SchemaDiff(from: base, to: changed)
        #expect(diff.changes.count == 3)
        for change in diff.changes {
            #expect(change.summary.hasSuffix("."))
        }
    }
}
