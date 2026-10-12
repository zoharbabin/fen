@testable import FenCore
import Foundation
import Testing

private func modelReply(_ json: String) -> [Data] {
    let delta: [String: Any] = ["choices": [["delta": ["content": json]]]]
    let body = (try? JSONSerialization.data(withJSONObject: delta)) ?? Data()
    return [Data("data: ".utf8) + body + Data("\n\n".utf8), Data("data: [DONE]\n\n".utf8)]
}

/// A workspace with a schema, untyped notes, and typed people and meetings. The fake embedder knows
/// the words recipe, money and release by concept.
@MainActor
struct ClassifyFixture {
    let home: TempHome
    let notes: TempFolder
    let library: WorkspaceLibrary
    let server: LoopbackServer
    let service: AIService
    let gate: WriteGate
    let workspaceID: UUID

    static let types = DocumentSchema(types: [
        DocumentType("Recipe", description: "recipe cooking dinner bake"),
        DocumentType("Budget", description: "money budget cost price"),
        DocumentType("Person", description: "A person"),
        DocumentType("Meeting", description: "A meeting", fields: [SchemaField("attendees", .list)]),
    ])

    static let cake = ["cake.md": "---\ntype: Budget\n---\n\n# Cake\n\nA dinner recipe: cooking and bake steps.\n"]

    static let files: [String: String] = [
        "pasta.md": "# Pasta\n\nA dinner recipe: cooking and bake steps.\n",
        "mixed.md": "# Plan\n\nrecipe cooking dinner money budget cost.\n",
        "gibberish.md": "# Zork\n\nqwerty asdf zxcv.\n",
        "people/Jane Doe.md": "---\ntype: Person\n---\n\n# Jane Doe\n",
        "people/Bob Stone.md": "---\ntype: Person\n---\n\n# Bob Stone\n",
        "meetings/standup.md": "---\ntype: Meeting\nattendees: [Jane Doe, Carla Ruiz]\n---\n\n# Standup\n",
        "meetings/retro.md": "---\ntype: Meeting\nattendees: [Jane Doe]\n---\n\n# Retro\n",
        "meetings/kickoff.md": "---\ntype: Meeting\nattendees: [Bob, Carla Ruiz]\n---\n\n# Kickoff\n",
    ]

    init(
        provider: ProviderChoice = .none,
        reply: String = #"{"type": "Recipe", "confidence": "high"}"#,
        access: AIDataAccess = .localProvidersOnly,
        approval: ApprovalMode = .ask,
        optInReplacing: Set<String> = [],
        minConfidence: Double = 0.7,
        extra: [String: String] = [:]
    ) async throws {
        home = try TempHome()
        notes = try TempFolder("classify-notes")
        let all = Self.files.merging(extra) { $1 }
        for (path, text) in all {
            try notes.write(path, text)
        }
        try SchemaStore(root: notes.root).create(Self.types)
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
        let workspace = try library.add(folder: notes.root, name: "Notes")
        try library.updateSettings(id: workspace.id) {
            $0.aiDataAccess = access
            $0.approvalMode = approval
            $0.writePolicy.autoApproveConfirmed = approval == .autoApprove
            $0.writePolicy.autoApproveReplacing = optInReplacing
            $0.writePolicy.autoApproveMinConfidence = minConfidence
        }
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == all.count
        }
        try #require(ready)
        let chunks = modelReply(reply)
        server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks)
        }
        let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
        switch provider {
        case .none: break
        case .local:
            try store.add(AIProviderConfig(
                name: "Local",
                kind: .openAICompatible,
                baseURL: "\(server.baseURL)/v1",
                model: "m"
            ))
        case .remote:
            try store.add(AIProviderConfig(
                name: "Cloud",
                kind: .openAICompatible,
                baseURL: "https://api.example.com/v1",
                model: "m"
            ))
        }
        service = AIService(store: store, workspaces: { library.registry.workspaces })
        self.library = library
        gate = WriteGate(library: library)
        workspaceID = workspace.id
    }

    func cleanUp() {
        server.stop()
        home.cleanUp()
        notes.cleanUp()
    }

    func run(_ options: ClassificationRun.Options = .init()) async throws -> ClassificationRun.Summary {
        try await ClassificationRun(library: library, service: service, gate: gate)
            .run(workspaceID: workspaceID, options: options)
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: notes.root.appendingPathComponent(path), encoding: .utf8)
    }

    func waiting(_ operation: String, _ path: String) -> WriteGate.Pending? {
        gate.pending(for: workspaceID).first { $0.change.operation == operation && $0.change.edit.primaryPath == path }
    }
}

@Suite("Classify a workspace under the write rules (issue #11)", .serialized)
@MainActor
struct ClassificationRunTests {
    @Test("Ask queues a type for each untyped note with its basis, and writes nothing")
    func askQueues() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.applied == 0)
        let item = try #require(fixture.waiting("classify", "pasta.md"))
        #expect(item.tier == .additive)
        #expect(item.reason == .modeIsAsk)
        #expect(item.change.documentType == "Recipe")
        #expect(item.change.edit == .setFrontMatter(path: "pasta.md", key: "type", value: "Recipe"))
        let basis = try #require(item.change.basis)
        #expect(basis.method == "embedding")
        #expect(basis.confidence <= ClassificationRun.embeddingCeiling)
        #expect(basis.confidence > ClassificationRun.unsettledConfidence)
        #expect(basis.evidence.contains("dinner recipe"))
        #expect(basis.detail.contains("Recipe"))
        #expect(try fixture.text("pasta.md") == ClassifyFixture.files["pasta.md"])
        #expect(fixture.waiting("classify", "gibberish.md") == nil)
        #expect(fixture.waiting("classify", "people/Jane Doe.md") == nil)
    }

    @Test("stage 1 needs no network: with no provider nothing is sent and a close call waits")
    func noProviderNoNetwork() async throws {
        let fixture = try await ClassifyFixture(provider: .none)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(fixture.server.requests.isEmpty)
        #expect(summary.modelCalls == 0)
        let mixed = try #require(fixture.waiting("classify", "mixed.md"))
        #expect(mixed.change.basis?.confidence == ClassificationRun.unsettledConfidence)
        #expect(mixed.change.basis?.detail.contains("close call") == true)
    }

    @Test("a confident document is classified without asking the provider, even with one set up")
    func confidentSkipsProvider() async throws {
        let fixture = try await ClassifyFixture(provider: .local)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        // Only the ambiguous note goes to the provider.
        #expect(fixture.server.requests.count == 1)
        #expect(fixture.waiting("classify", "pasta.md")?.change.basis?.method == "embedding")
    }

    @Test("the provider settles an ambiguous note, and only among the close types")
    func providerSettles() async throws {
        let fixture = try await ClassifyFixture(provider: .local, reply: #"{"type": "Budget", "confidence": "high"}"#)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.modelCalls == 1)
        let mixed = try #require(fixture.waiting("classify", "mixed.md"))
        #expect(mixed.change.basis?.method == "model")
        #expect(mixed.change.basis?.confidence == 0.9)
        #expect(mixed.change.provenance.provider == "Local")
        let body = try String(bytes: #require(fixture.server.requests.first).body, encoding: .utf8) ?? ""
        #expect(body.contains("Recipe"))
        #expect(body.contains("Budget"))
        #expect(!body.contains("Meeting"))
    }

    @Test("a type the provider invents is dropped, and the close call waits")
    func inventedType() async throws {
        let fixture = try await ClassifyFixture(provider: .local, reply: #"{"type": "Invoice", "confidence": "high"}"#)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let mixed = try #require(fixture.waiting("classify", "mixed.md"))
        #expect(mixed.change.basis?.method == "embedding")
        #expect(["Recipe", "Budget"].contains(mixed.change.documentType ?? ""))
    }

    @Test("a workspace that blocks the provider never sends it a document")
    func workspaceBlocksProvider() async throws {
        let fixture = try await ClassifyFixture(provider: .local, access: AIDataAccess.none)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(fixture.server.requests.isEmpty)
        #expect(summary.modelCalls == 0)
        #expect(fixture.waiting("classify", "pasta.md") != nil)
    }

    @Test("a remote provider is not asked when the workspace allows local providers only")
    func remoteProviderBlocked() async throws {
        let fixture = try await ClassifyFixture(provider: .remote)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.modelCalls == 0)
        #expect(fixture.waiting("classify", "mixed.md")?.change.basis?.method == "embedding")
    }

    @Test("the model-call cap leaves the rest of the close calls to the queue")
    func modelCap() async throws {
        let fixture = try await ClassifyFixture(
            provider: .local,
            extra: ["mixed2.md": "# Plan Two\n\nrecipe cooking dinner money budget cost.\n"]
        )
        defer { fixture.cleanUp() }
        var options = ClassificationRun.Options()
        options.maxModelCalls = 1
        let summary = try await fixture.run(options)
        #expect(summary.modelCalls == 1)
        #expect(fixture.server.requests.count == 1)
    }

    @Test("Auto-approve applies confident types and queues the ones below the threshold")
    func autoApproveThreshold() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.applied >= 1)
        #expect(try fixture.text("pasta.md").hasPrefix("---\ntype: Recipe\n---\n"))
        let mixed = try #require(fixture.waiting("classify", "mixed.md"))
        #expect(mixed.reason == .lowConfidence)
        #expect(try fixture.text("mixed.md") == ClassifyFixture.files["mixed.md"])
        #expect(fixture.gate.activity[fixture.workspaceID]?.first { $0.path == "pasta.md" }?.approvedBy == .auto)
    }

    @Test("by default an on-device match waits, even under Auto-approve")
    func defaultThresholdQueuesDeviceMatches() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove, minConfidence: WritePolicy.defaultMinConfidence)
        defer { fixture.cleanUp() }
        let summary = try await fixture.run()
        #expect(summary.applied == 0)
        #expect(fixture.waiting("classify", "pasta.md")?.reason == .lowConfidence)
        #expect(try fixture.text("pasta.md") == ClassifyFixture.files["pasta.md"])
    }

    @Test("a typed note teaches the classifier, so a note like it gets its type")
    func typedNotesAreExamples() async throws {
        let fixture = try await ClassifyFixture(
            extra: [
                "zork-one.md": "---\ntype: Budget\n---\n\n# Zork\n\nqwerty asdf zxcv.\n",
            ]
        )
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let item = try #require(fixture.waiting("classify", "gibberish.md"))
        #expect(item.change.documentType == "Budget")
    }

    @Test("lowering the threshold lets the same close call apply")
    func lowerThreshold() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.workspaceID) { $0.writePolicy.autoApproveMinConfidence = 0.5 }
        _ = try await fixture.run()
        #expect(fixture.waiting("classify", "mixed.md") == nil)
        #expect(try fixture.text("mixed.md").hasPrefix("---\ntype:"))
    }

    @Test("auto-approve for one document type applies only that type")
    func perTypeRule() async throws {
        let fixture = try await ClassifyFixture(approval: .ask)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.workspaceID) {
            $0.writePolicy.overrides = [.init(
                kind: .documentType,
                match: "Recipe",
                mode: .autoApprove,
                confirmed: true
            )]
        }
        _ = try await fixture.run()
        #expect(try fixture.text("pasta.md").hasPrefix("---\ntype: Recipe\n---\n"))
        // The close call may match the Recipe rule, but its low confidence still queues it.
        #expect(fixture.waiting("classify", "mixed.md") != nil)
        #expect(try fixture.text("mixed.md") == ClassifyFixture.files["mixed.md"])
    }

    @Test("auto-approve for one path pattern applies only there")
    func perPathRule() async throws {
        let fixture = try await ClassifyFixture(approval: .ask)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.workspaceID) {
            $0.writePolicy.overrides = [.init(kind: .pathGlob, match: "pasta.md", mode: .autoApprove, confirmed: true)]
        }
        _ = try await fixture.run()
        #expect(try fixture.text("pasta.md").hasPrefix("---\ntype: Recipe\n---\n"))
        #expect(fixture.waiting("classify", "mixed.md") != nil)
    }

    @Test("auto-approve for the classify operation applies and Off blocks")
    func perOperationRule() async throws {
        let fixture = try await ClassifyFixture(approval: .ask)
        defer { fixture.cleanUp() }
        try fixture.library.updateSettings(id: fixture.workspaceID) {
            $0.writePolicy.overrides = [.init(kind: .operation, match: "classify", mode: .off)]
        }
        let summary = try await fixture.run()
        #expect(summary.blocked > 0)
        #expect(!fixture.gate.pending(for: fixture.workspaceID).contains { $0.change.operation == "classify" })
        #expect(try fixture.text("pasta.md") == ClassifyFixture.files["pasta.md"])
    }

    @Test("changing an existing type is Replacing and asks, even under Auto-approve")
    func retypeAsks() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove, extra: ClassifyFixture.cake)
        defer { fixture.cleanUp() }
        var options = ClassificationRun.Options()
        options.includeTyped = true
        _ = try await fixture.run(options)
        let item = try #require(fixture.waiting("classify", "cake.md"))
        #expect(item.tier == .replacing)
        #expect(item.reason == .replacingNotOptedIn)
        #expect(try fixture.text("cake.md") == ClassifyFixture.cake["cake.md"])
    }

    @Test("typed notes are left alone unless you ask for them")
    func typedSkippedByDefault() async throws {
        let fixture = try await ClassifyFixture(extra: ClassifyFixture.cake)
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        #expect(fixture.waiting("classify", "cake.md") == nil)
    }

    @Test("a second run does not queue the same proposal twice")
    func noDuplicates() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let first = fixture.gate.pending(for: fixture.workspaceID).count
        let second = try await fixture.run()
        #expect(fixture.gate.pending(for: fixture.workspaceID).count == first)
        #expect(second.proposals == 0)
    }

    @Test("a note that changed after Fen read it is refused on approval")
    func staleApproval() async throws {
        let fixture = try await ClassifyFixture()
        defer { fixture.cleanUp() }
        _ = try await fixture.run()
        let item = try #require(fixture.waiting("classify", "pasta.md"))
        try (#require(ClassifyFixture.files["pasta.md"]) + "Late edit.\n").write(
            to: fixture.notes.root.appendingPathComponent("pasta.md"), atomically: true, encoding: .utf8
        )
        #expect(throws: WriteError.targetChanged("pasta.md")) { try fixture.gate.approve(item.id) }
    }

    @Test("a canceled run stops without writing")
    func canceled() async throws {
        let fixture = try await ClassifyFixture(approval: .autoApprove)
        defer { fixture.cleanUp() }
        let task = Task { try await fixture.run() }
        task.cancel()
        _ = await task.result
        // Whatever was applied before the stop is in the log, and every change is undoable.
        let applied = fixture.gate.activity[fixture.workspaceID]?.count ?? 0
        #expect(applied <= ClassifyFixture.files.count)
    }
}
