@testable import FenCore
import Foundation
import Testing

@Suite("Front matter links (issue #11)")
struct FrontMatterLinksTests {
    private let fields: Set<String> = ["attendees", "owner"]

    private func rewrite(_ lines: [String], to target: String = "jane-doe") -> [String] {
        FrontMatterLinks.rewrite(lines, fields: fields) { $0.value == "Jane" ? target : nil }
    }

    @Test("a plain value becomes a quoted link and keeps its comment")
    func scalar() {
        #expect(rewrite(["owner: Jane # lead"]) == ["owner: \"[[jane-doe]]\" # lead"])
        #expect(rewrite(["owner: \"Jane\""]) == ["owner: \"[[jane-doe]]\""])
    }

    @Test("a name in an inline list is replaced and the other items stay as written")
    func inlineList() {
        #expect(rewrite(["attendees: [Jane, 'Bob Stone', \"Cy, Jr\"]"])
            == ["attendees: [\"[[jane-doe]]\", 'Bob Stone', \"Cy, Jr\"]"])
    }

    @Test("a name in a block list is replaced under the right key only")
    func blockList() {
        let lines = ["attendees:", "  - Jane", "  - Bob", "tags:", "  - Jane"]
        #expect(rewrite(lines) == ["attendees:", "  - \"[[jane-doe]]\"", "  - Bob", "tags:", "  - Jane"])
    }

    @Test("fields that are not asked about are never touched")
    func otherFields() {
        #expect(rewrite(["title: Jane", "summary: Jane"]) == ["title: Jane", "summary: Jane"])
    }

    @Test("values that are not names are skipped")
    func notNames() {
        for value in [
            "2026-01-05",
            "42",
            "https://example.com/jane",
            "[[Jane]]",
            "Jane. Then Bob, later",
            "x",
            "one two three four five six",
        ] {
            #expect(!FrontMatterLinks.isMention(value), "\(value)")
        }
        #expect(FrontMatterLinks.isMention("Jane Doe"))
        #expect(FrontMatterLinks.mentions(in: ["owner: 2026-01-05"], fields: fields).isEmpty)
    }

    @Test("maps, anchors and block scalars are left alone")
    func complexValues() {
        let lines = ["owner: {name: Jane}", "attendees: |", "  Jane", "owner: *jane"]
        #expect(rewrite(lines) == lines)
        #expect(FrontMatterLinks.mentions(in: lines, fields: fields).isEmpty)
    }

    @Test("mentions lists every name in the fields")
    func mentions() {
        let found = FrontMatterLinks.mentions(
            in: ["owner: Jane", "attendees: [Bob, Cy]", "x: 1"], fields: fields
        )
        #expect(found == [
            .init(field: "owner", value: "Jane"), .init(field: "attendees", value: "Bob"),
            .init(field: "attendees", value: "Cy"),
        ])
    }

    @Test("replacingLines keeps CRLF and everything after the front matter")
    func crlf() throws {
        let text = "---\r\nowner: Jane\r\n---\r\n# Body\r\nowner: Jane\r\n"
        let lines = try #require(FrontMatterEditor.lines(of: text))
        let out = try #require(FrontMatterEditor.replacingLines(in: text, with: rewrite(lines)))
        #expect(out == "---\r\nowner: \"[[jane-doe]]\"\r\n---\r\n# Body\r\nowner: Jane\r\n")
    }
}

@Suite("Resolving names to documents (issue #11)")
struct LinkResolverTests {
    private func resolver(_ items: [(String, String)]) -> LinkResolver {
        let targets = items.map { LinkTarget(path: $0.0, title: $0.1, type: "Person") }
        return LinkResolver(targets: targets, allPaths: targets.map(\.path))
    }

    private let people = [("people/jane-doe.md", "Jane Doe"), ("people/bob.md", "Bob Stone"), ("people/Zoë.md", "")]

    @Test("an equal title matches with high confidence, case and spacing aside")
    func title() {
        guard case let .match(target, method) = resolver(people).resolve("  jane   DOE ", excluding: "x.md") else {
            Issue.record("expected a match")
            return
        }
        #expect(target.path == "people/jane-doe.md")
        #expect(method == .title)
        #expect(method.confidence > LinkMatchMethod.filename.confidence - 0.1)
    }

    @Test("an equal file name matches, and accents don't matter")
    func filename() {
        guard case let .match(target, method) = resolver(people).resolve("Zoe", excluding: "x.md") else {
            Issue.record("expected a match")
            return
        }
        #expect(target.path == "people/Zoë.md")
        #expect(method == .filename)
    }

    @Test("a first name matches one longer name as a guess")
    func namePart() {
        guard case let .match(target, method) = resolver(people).resolve("Jane", excluding: "x.md") else {
            Issue.record("expected a match")
            return
        }
        #expect(target.path == "people/jane-doe.md")
        #expect(method == .namePart)
        #expect(method.confidence < WritePolicy.defaultMinConfidence)
    }

    @Test("a name that fits two documents is ambiguous, not guessed")
    func ambiguous() {
        let both = resolver([("a/jane-doe.md", "Jane Doe"), ("b/jane-roe.md", "Jane Roe")])
        guard case let .ambiguous(found) = both.resolve("Jane", excluding: "x.md") else {
            Issue.record("expected ambiguous")
            return
        }
        #expect(found.count == 2)
        let twins = resolver([("a/jane.md", "Jane"), ("b/jane.md", "Jane")])
        guard case .ambiguous = twins.resolve("Jane", excluding: "x.md") else {
            Issue.record("expected ambiguous")
            return
        }
    }

    @Test("short fragments and unknown names match nothing")
    func nothing() {
        let known = resolver(people)
        #expect(known.resolve("Jo", excluding: "x.md") == .none)
        #expect(known.resolve("Carla Ruiz", excluding: "x.md") == .none)
        #expect(known.resolve("Jane Roe", excluding: "x.md") == .none)
        #expect(known.resolve("", excluding: "x.md") == .none)
    }

    @Test("a document never links to itself")
    func notSelf() {
        #expect(resolver(people).resolve("Jane Doe", excluding: "people/jane-doe.md") == .none)
    }

    @Test("the link is the file name, or the path when another file has that name")
    func linkText() {
        let unique = resolver(people)
        #expect(unique.linkText(for: LinkTarget(path: "people/jane-doe.md", title: "", type: "Person")) == "jane-doe")
        let targets = [
            LinkTarget(path: "a/jane.md", title: "Jane", type: "P"),
            LinkTarget(path: "b/jane.md", title: "", type: "P"),
        ]
        let clash = LinkResolver(targets: targets, allPaths: targets.map(\.path))
        #expect(clash.linkText(for: targets[0]) == "a/jane")
    }
}

@Suite("Planning links and stubs (issue #11)")
struct LinkPlannerTests {
    private let schema = DocumentSchema(types: [
        DocumentType("Person", description: "A person"),
        DocumentType("Meeting", description: "A meeting", fields: [
            SchemaField("attendees", .list), SchemaField("notes", .text), SchemaField("when", .date),
        ]),
    ])

    private func person(_ name: String, folder: String = "people") -> LinkDocument {
        LinkDocument(
            path: "\(folder)/\(name).md",
            title: name,
            text: "---\ntype: Person\n---\n\n# \(name)\n",
            type: "Person"
        )
    }

    private func meeting(_ name: String, attendees: String, body: String = "") -> LinkDocument {
        LinkDocument(
            path: "meetings/\(name).md",
            title: name,
            text: "---\ntype: Meeting\nattendees: \(attendees)\n---\n\n# \(name)\n\(body)",
            type: "Meeting"
        )
    }

    @Test("a resolved name becomes a rewrite whose confidence is the weakest link")
    func rewrite() throws {
        let plan = LinkPlanner.plan(
            documents: [person("Jane Doe"), person("Bob Stone"), meeting("standup", attendees: "[Jane Doe, Bob]")],
            schema: schema
        )
        let rewrite = try #require(plan.rewrites.first)
        #expect(plan.rewrites.count == 1)
        #expect(rewrite.path == "meetings/standup.md")
        #expect(rewrite.after.contains("attendees: [\"[[Jane Doe]]\", \"[[Bob Stone]]\"]"))
        #expect(rewrite.links.map(\.method) == [.title, .namePart])
        #expect(rewrite.confidence == LinkMatchMethod.namePart.confidence)
    }

    @Test("names in the body are never read")
    func bodyIgnored() {
        let plan = LinkPlanner.plan(
            documents: [person("Jane Doe"), meeting("standup", attendees: "[Cy]", body: "Jane Doe was there.\n")],
            schema: schema
        )
        #expect(plan.rewrites.isEmpty)
    }

    @Test("a document whose type is not in the schema, or a field that is not text or a list, is skipped")
    func onlySchemaFields() {
        var odd = meeting("odd", attendees: "[Jane Doe]")
        odd = LinkDocument(
            path: odd.path,
            title: odd.title,
            text: odd.text.replacingOccurrences(of: "Meeting", with: "Other"),
            type: "Other"
        )
        let dated = LinkDocument(
            path: "meetings/dated.md",
            title: "dated",
            text: "---\ntype: Meeting\nwhen: Jane Doe\n---\n",
            type: "Meeting"
        )
        #expect(LinkPlanner.plan(documents: [person("Jane Doe"), odd, dated], schema: schema).rewrites.isEmpty)
    }

    @Test("an ambiguous name is reported and proposes nothing")
    func ambiguous() {
        let plan = LinkPlanner.plan(
            documents: [person("Jane Doe"), person("Jane Roe"), meeting("m", attendees: "[Jane]")],
            schema: schema
        )
        #expect(plan.rewrites.isEmpty)
        #expect(plan.ambiguous.count == 1)
        #expect(plan.ambiguous[0].contains("people/Jane Doe.md"))
    }

    @Test("a stub is offered for a missing name in a field that already holds links")
    func stub() throws {
        let plan = LinkPlanner.plan(
            documents: [
                person("Jane Doe"), person("Bob Stone"),
                meeting("a", attendees: "[Jane Doe, Bob Stone]"),
                meeting("b", attendees: "[Carla Ruiz]"),
                meeting("c", attendees: "[Carla Ruiz]"),
            ],
            schema: schema
        )
        let stub = try #require(plan.stubs.first)
        #expect(plan.stubs.count == 1)
        #expect(stub.path == "people/Carla Ruiz.md")
        #expect(stub.type == "Person")
        #expect(stub.content == "---\ntype: Person\n---\n\n# Carla Ruiz\n")
        #expect(stub.mentionedIn == ["meetings/b.md", "meetings/c.md"])
    }

    @Test("no stub for a field with one match, or when the file already exists")
    func noStub() {
        let one = LinkPlanner.plan(
            documents: [
                person("Jane Doe"),
                meeting("a", attendees: "[Jane Doe]"),
                meeting("b", attendees: "[Carla Ruiz]"),
            ],
            schema: schema
        )
        #expect(one.stubs.isEmpty)
        let existing = LinkDocument(path: "people/carla ruiz.md", title: "", text: "Just notes.\n", type: nil)
        let taken = LinkPlanner.plan(
            documents: [
                person("Jane Doe"), person("Bob Stone"), existing,
                meeting("a", attendees: "[Jane Doe, Bob Stone]"), meeting("b", attendees: "[Carla Ruiz]"),
            ],
            schema: schema
        )
        #expect(taken.stubs.isEmpty)
    }

    @Test("a stub file name is safe")
    func fileName() {
        #expect(LinkPlanner.fileName(for: "Ann/../B: C") == "Ann..B C.md")
        #expect(LinkPlanner.fileName(for: "...") == nil)
        #expect(LinkPlanner.fileName(for: "[[#]]") == nil)
        #expect(LinkPlanner.fileName(for: " Ann  Lee ") == "Ann Lee.md")
    }
}
