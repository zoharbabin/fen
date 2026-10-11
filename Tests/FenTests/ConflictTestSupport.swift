@testable import FenCore
import Foundation
import Testing

func conflictReply(_ json: String) -> [Data] {
    let delta: [String: Any] = ["choices": [["delta": ["content": json]]]]
    let body = (try? JSONSerialization.data(withJSONObject: delta)) ?? Data()
    return [Data("data: ".utf8) + body + Data("\n\n".utf8), Data("data: [DONE]\n\n".utf8)]
}

/// A workspace of notes in `docs/`, a fake on-device embedder, and a provider on loopback.
/// The embedder knows the concepts release, money and cat.
@MainActor
struct ConflictFixture {
    static let verdictYes = #"{"conflict": true, "confidence": "high", "outdated": "second", "explanation": "One says two weeks, the other four."}"#
    static let verdictNo = #"{"conflict": false, "confidence": "high", "outdated": "unclear", "explanation": "They fit."}"#

    static let policy = "# Policy\n\nWe ship the release every 2 weeks on Thursday, with no exceptions.\n"
    static let handbook = "# Handbook\n\nWe ship the release every 4 weeks on Monday.\n"
    static let lunch = "# Lunch\n\nThe cat sleeps on the kitchen chair all afternoon long.\n"

    let home: TempHome
    let notes: TempFolder
    let library: WorkspaceLibrary
    let server: LoopbackServer
    let service: AIService
    let gate: WriteGate
    let workspaceID: UUID
    let embedder: FakeEmbedder?
    let git: GitTool?

    init(
        provider: ProviderChoice = .none,
        reply: String = ConflictFixture.verdictYes,
        access: AIDataAccess = .localProvidersOnly,
        approval: ApprovalMode = .ask,
        optInReplacing: Set<String> = [],
        useGit: Bool = false,
        embedderless: Bool = false,
        files: [String: String] = [
            "docs/policy.md": ConflictFixture.policy,
            "docs/handbook.md": ConflictFixture.handbook,
            "docs/lunch.md": ConflictFixture.lunch,
        ]
    ) async throws {
        home = try TempHome()
        notes = try TempFolder("conflict-notes")
        for (path, text) in files {
            try notes.write(path, text)
        }
        if useGit {
            try notes.git("init", "-q", "-b", "main")
            try notes.git("add", "-A")
            try notes.git("commit", "-q", "-m", "init")
        }
        git = useGit ? GitFixture.tool : nil
        embedder = embedderless ? nil : FakeEmbedder()
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: embedder)
        let workspace = try library.add(folder: notes.root, name: "Notes")
        try library.updateSettings(id: workspace.id) {
            $0.aiDataAccess = access
            $0.approvalMode = approval
            $0.writePolicy.autoApproveConfirmed = approval == .autoApprove
            $0.writePolicy.autoApproveReplacing = optInReplacing
        }
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: workspace.id)
            return embedderless || (status.phase == .idle && status.documents == files.count)
        }
        try #require(ready)
        let chunks = conflictReply(reply)
        server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks)
        }
        let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
        switch provider {
        case .none: break
        case .local:
            try store.add(AIProviderConfig(
                name: "Local", kind: .openAICompatible, baseURL: "\(server.baseURL)/v1", model: "m"
            ))
        case .remote:
            try store.add(AIProviderConfig(
                name: "Cloud", kind: .openAICompatible, baseURL: "https://api.example.com/v1", model: "m"
            ))
        }
        service = AIService(store: store, workspaces: { library.registry.workspaces })
        self.library = library
        gate = WriteGate(
            home: library.registry.home,
            workspaces: { library.workspaces },
            rootURL: { try library.registry.rootURL(for: $0) },
            agentBranches: AgentBranches(git: GitFixture.tool)
        )
        workspaceID = workspace.id
    }

    func cleanUp() {
        server.stop()
        home.cleanUp()
        notes.cleanUp()
    }

    func run(_ options: ConflictRun.Options = .init()) async throws -> ConflictRun.Summary {
        try await ConflictRun(library: library, service: service, gate: gate, git: git)
            .run(workspaceID: workspaceID, options: options)
    }

    var resolver: ConflictResolver {
        ConflictResolver(library: library, service: service, gate: gate)
    }

    var store: ConflictStore {
        ConflictStore(file: gate.home.conflictsFile(id: workspaceID))
    }

    /// Saves a flag for the policy and handbook notes, the pair the fixture is built around.
    @discardableResult
    func plantFlag() throws -> ConflictFlag {
        func side(_ path: String) throws -> ConflictSide {
            let passage = try #require(ConflictPassage.split(text(path)).first)
            return ConflictSide(path: path, passage: passage)
        }
        let flag = try ConflictFlag(
            id: UUID(), changed: side("docs/handbook.md"), other: side("docs/policy.md"), confidence: 0.9,
            method: "model", explanation: "Two weeks or four.", created: Date(), status: .open, resolution: nil,
            staleSide: nil
        )
        var state = state()
        state.flags = [flag]
        try store.save(state)
        return flag
    }

    func state() -> ConflictState {
        store.load()
    }

    func text(_ path: String) throws -> String {
        try String(contentsOf: notes.root.appendingPathComponent(path), encoding: .utf8)
    }

    /// Lists the workspace again and waits until it shows exactly `paths`.
    func rescan(expecting paths: Set<String>) async throws {
        library.scan(workspaceID)
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            Set(library.state(for: workspaceID).snapshot.documents.map(\.relativePath)) == paths
                && library.indexStatus(for: workspaceID).phase == .idle
        }
        try #require(ready)
    }

    /// Everything in the workspace folder, to prove a run leaves it alone.
    func listing() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(
            at: notes.root, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.path.replacingOccurrences(of: notes.root.path + "/", with: "")
            if name.hasPrefix(".git/") || name == ".git" {
                continue
            }
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                result[name] = try Data(contentsOf: url)
            }
        }
        return result
    }
}
