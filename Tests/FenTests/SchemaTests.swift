@testable import FenCore
import Foundation
import Testing

@Suite("Document schema (issue #7)")
struct SchemaTests {
    @Test("versions order by number, not by text")
    func versionOrder() throws {
        let nine = try #require(SchemaVersion("1.9.0"))
        let ten = try #require(SchemaVersion("1.10.0"))
        #expect(nine < ten)
        #expect(SchemaVersion("1.0") == nil)
        #expect(SchemaVersion("a.b.c") == nil)
        #expect(SchemaVersion("1.-1.0") == nil)
        #expect(nine.bumpedMinor == ten)
        #expect(ten.bumpedMajor == SchemaVersion(2, 0, 0))
    }

    @Test("the default schema has the six universal types and every pack type is valid and unique")
    func startersAreValid() throws {
        #expect(SchemaStarters.universal.map(\.name) == [
            "Person",
            "Project",
            "Meeting",
            "Task",
            "Journal",
            "Reference",
        ])
        let packs = Dictionary(uniqueKeysWithValues: SchemaStarters.packs.map { ($0.id, $0.types.map(\.name)) })
        #expect(packs["sales"] == ["Deal", "Account"])
        #expect(packs["engineering"] == ["ADR", "Bug"])
        #expect(packs["writer"] == ["Character", "Scene"])
        #expect(packs["student"] == ["Course", "Concept"])
        let all = SchemaStarters.universal + SchemaStarters.packs.flatMap(\.types)
        #expect(Set(all.map(\.name)).count == all.count)
        try DocumentSchema(version: SchemaVersion(1), types: all).validate()
        for type in all {
            #expect(!type.description.isEmpty)
        }
    }

    @Test("a schema survives a write and a read, in the same order")
    func roundTrip() throws {
        let everything = SchemaStarters.universal + SchemaStarters.packs.flatMap(\.types)
        let schema = DocumentSchema(version: SchemaVersion(2, 3, 1), types: everything)
        let back = try DocumentSchema(yaml: schema.yaml)
        #expect(back == schema)
        #expect(back.yaml == schema.yaml)
    }

    @Test("awkward text in names, values, and descriptions round-trips")
    func awkwardText() throws {
        var type = DocumentType("Odd", description: "Has \"quotes\", a: colon,\nand a line break.")
        type.fields = [
            SchemaField(
                "flag",
                .choice,
                values: ["yes", "no", "1", "a, b", "x\"y", "true"],
                description: "# not a comment"
            ),
            SchemaField("note", .text, required: true, description: "ünïcode ✓"),
            SchemaField("gone", .boolean, hidden: true),
        ]
        type.hidden = true
        let schema = DocumentSchema(version: SchemaVersion(1), types: [type])
        let back = try DocumentSchema(yaml: schema.yaml)
        #expect(back.types[0].fields == type.fields)
        #expect(back.types[0].hidden)
        #expect(back.types[0].description == "Has \"quotes\", a: colon, and a line break.")
    }

    @Test("a hand-written file with unknown keys and a newer minor version still loads")
    func toleratesUnknownKeys() throws {
        let yaml = """
        schema_version: 1.7.0
        owner: someone
        types:
          Person:
            description: A person.
            color: red
            fields:
              name:
                type: string
                x-future: 1
              age:
                type: integer
        """
        let schema = try DocumentSchema(yaml: yaml)
        #expect(schema.version == SchemaVersion(1, 7, 0))
        #expect(schema.type(named: "Person")?.field(named: "age")?.kind == .number)
    }

    @Test("a schema you moved to a new major version still loads")
    func laterMajorLoads() throws {
        #expect(try DocumentSchema(yaml: "schema_version: 4.0.0\ntypes: {}\n").version == SchemaVersion(4))
    }

    @Test("a bad version, a missing version, and bad names are refused with a clear error")
    func refusals() {
        #expect(throws: SchemaError.missingVersion) { try DocumentSchema(yaml: "types: {}\n") }
        #expect(throws: SchemaError.badVersion("one")) { try DocumentSchema(yaml: "schema_version: one\n") }
        #expect(throws: SchemaError.notYAML) { try DocumentSchema(yaml: "- just\n- a list\n") }
        #expect(throws: SchemaError.badName("bad name")) {
            try DocumentSchema(yaml: "schema_version: 1.0.0\ntypes:\n  bad name:\n    description: x\n")
        }
        #expect(throws: SchemaError.self) {
            try DocumentSchema(
                yaml: "schema_version: 1.0.0\ntypes:\n  A:\n    fields:\n      f:\n        type: object\n"
            )
        }
    }

    @Test("the file reads as plain text a person can follow")
    func readable() {
        let yaml = SchemaStarters.defaultSchema.yaml
        #expect(yaml.hasPrefix("# Document types"))
        #expect(yaml
            .contains("schema_version: 1.0.0\ntypes:\n  Person:\n    description: A person you know or work with.\n"))
        #expect(yaml.contains("        enum: [planned, active, paused, done]"))
        #expect(yaml.contains("        format: date"))
    }
}

@Suite("Schema changes (issue #7)")
struct SchemaDiffTests {
    private let base = SchemaStarters.defaultSchema

    private func edit(_ change: (inout DocumentSchema) -> Void) -> SchemaDiff {
        var copy = base
        change(&copy)
        return SchemaDiff(from: base, to: copy)
    }

    @Test("no change is empty and keeps the version")
    func unchanged() {
        let diff = SchemaDiff(from: base, to: base)
        #expect(diff.isEmpty)
        #expect(diff.autoVersion(after: base.version) == base.version)
    }

    @Test("every additive change is not breaking and bumps the minor version")
    func additive() {
        let diffs = [
            edit { $0.types.append(DocumentType("New", description: "x")) },
            edit { $0.types[0].fields.append(SchemaField("extra")) },
            edit { $0.types[1].fields[0].values.append("cancelled") },
            edit { $0.types[2].fields[0].required = false },
            edit { $0.types[0].description = "Changed" },
            edit { $0.types[0].hidden = true },
            edit { $0.types[0].fields[0].hidden = true },
        ]
        for diff in diffs {
            #expect(!diff.isEmpty)
            #expect(!diff.isBreaking)
            #expect(diff.autoVersion(after: SchemaVersion(1, 2, 0)) == SchemaVersion(1, 3, 0))
        }
    }

    @Test("every breaking change is flagged and needs the user to choose a major version")
    func breaking() {
        let diffs = [
            edit { $0.types.removeLast() },
            edit { $0.types[0].fields.removeFirst() },
            edit { $0.types[0].fields[0].kind = .number },
            edit { $0.types[1].fields[0].values.removeLast() },
            edit { $0.types[0].fields[0].required = true },
            edit { $0.types[0].fields.append(SchemaField("must", required: true)) },
        ]
        for diff in diffs {
            #expect(diff.isBreaking)
            #expect(diff.autoVersion(after: base.version) == nil)
        }
    }

    @Test("validate refuses a breaking change without a major bump and any change without a bump")
    func validation() throws {
        let breaking = edit { $0.types.removeLast() }
        #expect(throws: SchemaError.breakingNeedsMajor) {
            try breaking.validate(from: SchemaVersion(1), to: SchemaVersion(1, 1, 0))
        }
        #expect(throws: SchemaError.versionNotRaised) {
            try breaking.validate(from: SchemaVersion(1), to: SchemaVersion(1))
        }
        try breaking.validate(from: SchemaVersion(1), to: SchemaVersion(2))
        let additive = edit { $0.types.append(DocumentType("New", description: "x")) }
        #expect(throws: SchemaError.versionNotRaised) {
            try additive.validate(from: SchemaVersion(1), to: SchemaVersion(1))
        }
        try additive.validate(from: SchemaVersion(1), to: SchemaVersion(1, 0, 1))
    }

    @Test("random edits: a diff that is not breaking never loses a type, field, or value")
    func randomizedAdditiveMeansNothingLost() {
        var generator = SeededGenerator(seed: 7)
        for _ in 0 ..< 300 {
            var schema = base
            for _ in 0 ..< Int.random(in: 1 ... 4, using: &generator) {
                mutate(&schema, using: &generator)
            }
            let diff = SchemaDiff(from: base, to: schema)
            guard !diff.isBreaking else { continue }
            for type in base.types {
                guard let kept = schema.type(named: type.name) else {
                    Issue.record("type \(type.name) lost by a non-breaking diff")
                    continue
                }
                for field in type.fields {
                    let after = kept.field(named: field.name)
                    #expect(after?.kind == field.kind)
                    #expect(Set(field.values).isSubset(of: Set(after?.values ?? [])))
                    #expect(after?.required != true || field.required)
                }
            }
        }
    }

    private func mutate(_ schema: inout DocumentSchema, using generator: inout SeededGenerator) {
        let typeIndex = Int.random(in: 0 ..< schema.types.count, using: &generator)
        let fieldCount = schema.types[typeIndex].fields.count
        switch Int.random(in: 0 ..< 9, using: &generator) {
        case 0: schema.types.remove(at: typeIndex)
        case 1 where fieldCount > 0:
            schema.types[typeIndex].fields.remove(at: Int.random(in: 0 ..< fieldCount, using: &generator))
        case 2 where fieldCount > 0:
            schema.types[typeIndex].fields[Int.random(in: 0 ..< fieldCount, using: &generator)].kind = .boolean
        case 3 where fieldCount > 0:
            let index = Int.random(in: 0 ..< fieldCount, using: &generator)
            schema.types[typeIndex].fields[index].required.toggle()
        case 4 where fieldCount > 0:
            let index = Int.random(in: 0 ..< fieldCount, using: &generator)
            if !schema.types[typeIndex].fields[index].values.isEmpty {
                schema.types[typeIndex].fields[index].values.removeLast()
            }
        case 5: schema.types[typeIndex].fields.append(SchemaField("n\(Int.random(in: 0 ... 99, using: &generator))"))
        case 6: schema.types.append(DocumentType("T\(Int.random(in: 0 ... 99, using: &generator))", description: "x"))
        case 7: schema.types[typeIndex].description += "!"
        default: schema.types[typeIndex].hidden.toggle()
        }
    }
}

/// A repeatable random source, so a failure can be replayed.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
