@testable import FenCore
import Foundation
import Testing

/// One workspace folder, one home, and a gate wired to them.
@MainActor
final class GateHarness {
    let folder: TempFolder
    let homeFolder: TempHome
    var workspaces: [Workspace]
    let gate: WriteGate
    let workspaceID = UUID()
    let runID = UUID()

    init(
        files: [String: String] = ["a.md": "# A\n\nOne.\n", "b.md": "# B\n"],
        settings: WorkspaceSettings = WorkspaceSettings(),
        git: Bool = false
    ) throws {
        folder = try TempFolder("writes")
        homeFolder = try TempHome()
        for (path, text) in files {
            try folder.write(path, text)
        }
        if git {
            try folder.write(".gitignore", "build/\n")
            try folder.initRepo()
            try folder.commitAll("init")
        }
        let workspace = Workspace(id: workspaceID, name: "W", path: folder.root.path, settings: settings)
        workspaces = [workspace]
        gate = Self.makeGate(home: homeFolder.home, root: folder.root, workspace: { [workspace] in [workspace] })
    }

    /// A second gate over the same home, as after a restart.
    func restartedGate() -> WriteGate {
        let all = workspaces
        return Self.makeGate(home: homeFolder.home, root: folder.root, workspace: { all })
    }

    private static func makeGate(
        home: FenHome,
        root: URL,
        workspace: @escaping @MainActor () -> [Workspace]
    ) -> WriteGate {
        WriteGate(home: home, workspaces: workspace, rootURL: { _ in root })
    }

    func cleanUp() {
        folder.cleanUp()
        homeFolder.cleanUp()
    }

    func text(_ path: String) -> String? {
        try? String(contentsOf: folder.root.appendingPathComponent(path), encoding: .utf8)
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.root.appendingPathComponent(path).path)
    }

    func change(
        _ edit: EditOperation,
        operation: String = "enrich",
        scope: Set<String>? = nil,
        base: String?? = nil,
        invoked: Bool = false,
        run: UUID? = nil,
        client: String? = nil
    ) throws -> ProposedChange {
        let target = edit.primaryPath
        let hash: String? = switch base {
        case let .some(value): value
        case .none: try gate.contentHash(workspaceID: workspaceID, relativePath: target)
        }
        return ProposedChange(
            workspaceID: workspaceID,
            runID: run ?? runID,
            operation: operation,
            client: client,
            edit: edit,
            scope: scope ?? Set(edit.paths),
            baseHash: hash,
            invokedByUser: invoked,
            provenance: Provenance(provider: "Ollama", model: "llama3", sources: ["b.md"])
        )
    }
}

/// Auto-approve confirmed, with replacing edits opted in for `enrich`.
func autoSettings(replacing: Bool = true, maxFiles: Int = 20, maxFraction: Double = 0.5) -> WorkspaceSettings {
    WorkspaceSettings(
        approvalMode: .autoApprove,
        writePolicy: WritePolicy(
            autoApproveConfirmed: true,
            autoApproveReplacing: replacing ? ["enrich"] : [],
            maxFilesPerRun: maxFiles,
            maxChangedFraction: maxFraction
        )
    )
}
