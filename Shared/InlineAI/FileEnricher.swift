import Foundation

/// Enriches the short bullets of a whole workspace file, and sends the result through the write
/// gate (issues #6, #140). A person is not watching, so the workspace's approval mode decides:
/// Ask queues a diff and writes nothing, Auto-approve adds the facts (they only add lines), Off does nothing.
@MainActor
struct FileEnricher {
    enum Result: Equatable {
        /// A diff waits in the workspace's activity list.
        case queued
        case applied
        /// Nothing was written, and why.
        case nothing(String)
    }

    let library: WorkspaceLibrary
    let service: AIService
    let gate: WriteGate

    func enrich(workspaceID: UUID, relativePath: String) async throws -> Result {
        guard let url = library.fileURL(workspaceID: workspaceID, relativePath: relativePath),
              let workspace = library.registry.workspace(id: workspaceID) else {
            return .nothing("Fen can't read that file. It is outside the workspace or no longer listed.")
        }
        if let reason = InlineAIAccess.reason(library: library, service: service, fileURL: url, operation: "enrich") {
            return .nothing(reason)
        }
        // The hash comes first. If the file changes after this, the gate refuses the write.
        let baseHash = try gate.contentHash(workspaceID: workspaceID, relativePath: relativePath)
        let text = try String(contentsOf: url, encoding: .utf8)
        let bullets = Enrichment.bullets(in: text, shorthandOnly: true)
        guard !bullets.isEmpty else { return .nothing("This file has no short bullets to enrich.") }
        let result = try await EnrichmentPipeline.run(
            text: text, bullets: bullets, workspace: workspace, path: relativePath, library: library, service: service
        )
        guard case let .enriched(outcome, passages) = result else {
            return .nothing(result.reason)
        }
        let config = service.store.selected
        let change = ProposedChange(
            workspaceID: workspaceID,
            operation: "enrich",
            edit: .insertBelow(path: relativePath, insertions: outcome.insertions),
            scope: [relativePath],
            baseHash: baseHash,
            invokedByUser: false,
            provenance: Provenance(
                provider: config?.name ?? "",
                model: config?.model ?? "",
                sources: Array(Set(passages.map(\.relativePath))).sorted()
            )
        )
        switch try gate.submit(change) {
        case .applied: return .applied
        case .pending: return .queued
        case .blocked: return .nothing("AI changes are off in \(workspace.name).")
        }
    }
}
