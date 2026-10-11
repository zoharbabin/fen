import Foundation

/// Finds the notes behind some bullets, asks the model, and places the checked facts (issue #6).
/// The selection in the editor and a whole file in the workspace share this, so both follow the same
/// rules: nothing is sent without supporting notes, and no fact is kept without a citation.
@MainActor
enum EnrichmentPipeline {
    enum Result {
        case enriched(EnrichmentOutcome, passages: [Passage])
        /// Nothing to do, and why. Not an error.
        case nothing(String)

        var reason: String {
            if case let .nothing(why) = self {
                return why
            }
            return "Nothing was changed."
        }
    }

    /// `onPiece` sees the answer as it streams in. Throws when the provider fails or the run is canceled.
    static func run(
        text: String,
        bullets: [EnrichmentBullet],
        workspace: Workspace,
        path: String,
        library: WorkspaceLibrary,
        service: AIService,
        onPiece: (String) -> Void = { _ in }
    ) async throws -> Result {
        let destination = try service.destination()
        let passages = await gather(
            for: bullets,
            workspace: workspace,
            path: path,
            destination: destination,
            library: library
        )
        guard !passages.isEmpty else {
            return .nothing("No note in this workspace supports these bullets. Nothing was changed.")
        }
        var reply = ""
        for try await piece in try service.send(
            prompt: Enrichment.prompt(for: bullets), context: AskPrompt.context(for: passages)
        ) {
            reply += piece
            onPiece(piece)
        }
        try Task.checkCancellation()
        let facts = Enrichment.facts(in: reply, bulletCount: bullets.count, passages: passages)
        let outcome = Enrichment.apply(facts, to: text, bullets: bullets, passages: passages, from: path)
        guard !outcome.enriched.isEmpty else { return .nothing(outcome.summary) }
        return .enriched(outcome, passages: passages)
    }

    /// The best passages from the rest of the workspace for each bullet. It never reads a file.
    private static func gather(
        for bullets: [EnrichmentBullet],
        workspace: Workspace,
        path: String,
        destination: ModelDestination,
        library: WorkspaceLibrary
    ) async -> [Passage] {
        library.start()
        var found: [Passage] = []
        var seen = Set<String>()
        for bullet in bullets {
            let keywords = RelatedQuery.keywords(from: bullet.text)
            let results = await library.search.search(
                keywords.isEmpty ? bullet.text : keywords,
                meaning: bullet.text,
                anyWord: true,
                in: library.registry.workspaces,
                scope: .workspace(workspace.id),
                destination: destination,
                limit: Enrichment.passagesPerBullet + 2
            )
            let others = results.filter { $0.relativePath != path }.prefix(Enrichment.passagesPerBullet)
            for passage in await library.search.passages(for: Array(others)) where seen.insert(passage.id).inserted {
                found.append(passage)
            }
        }
        return AskPrompt.fitting(found)
    }
}
