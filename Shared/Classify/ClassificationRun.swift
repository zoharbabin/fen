import Foundation

/// Finds types and links across a whole workspace and sends each proposal through the write gate
/// (issue #11). Nobody is watching, so the workspace's approval mode decides what happens: Ask
/// fills the review queue, Auto-approve applies only what clears the confidence threshold, and
/// Off proposes nothing that gets written.
///
/// Stage 1 runs on the device. The provider is asked only about ambiguous documents, only when one
/// is configured, and only if the workspace's AI data access allows it.
@MainActor
struct ClassificationRun {
    struct Options: Equatable {
        /// Also propose a new type for documents that already have one. Replacing, so it asks.
        var includeTyped = false
        /// The most documents sent to the provider in one run.
        var maxModelCalls = 25
    }

    struct Summary: Equatable {
        var scanned = 0
        var typeProposals = 0
        var linkProposals = 0
        var stubProposals = 0
        var applied = 0
        var queued = 0
        var blocked = 0
        var modelCalls = 0
        /// Why something was left out, one line each.
        var notes: [String] = []

        /// What the run did, in a few plain lines for an alert.
        var text: String {
            if scanned == 0, !notes.isEmpty {
                return notes.joined(separator: "\n")
            }
            var lines = ["Read \(scanned) notes."]
            if proposals == 0 {
                lines.append("Nothing to change.")
            } else {
                lines.append("\(typeProposals) types, \(linkProposals) link fixes, \(stubProposals) new notes.")
                if applied > 0 {
                    lines.append("\(applied) applied. You can undo them in Activity.")
                }
                if queued > 0 {
                    lines.append("\(queued) wait for you in Activity.")
                }
                if blocked > 0 {
                    lines.append("\(blocked) skipped because the rules turn them off.")
                }
            }
            if modelCalls > 0 {
                lines.append("Asked your model about \(modelCalls) close calls.")
            }
            return (lines + notes.prefix(3)).joined(separator: "\n")
        }

        var proposals: Int {
            typeProposals + linkProposals + stubProposals
        }
    }

    /// The most bytes of a file that is read. Larger files are skipped, as related-document search does.
    static let maxBytes = SchemaMigration.maxBytes
    /// What a close call between types is worth when no provider settles it. Below the default threshold.
    /// The most an on-device match can claim. It sits under `WritePolicy.defaultMinConfidence`, so
    /// these matches wait for you until you lower the threshold. The model separates types only so
    /// well (`TypeClassifierPrecisionTests`).
    static let embeddingCeiling = 0.75
    static let examplesPerType = 10
    static let unsettledConfidence = 0.5
    /// What a stub is worth. It is a guess at a new file, so it waits for you by default.
    static let stubConfidence = 0.6

    let library: WorkspaceLibrary
    let service: AIService
    let gate: WriteGate

    /// `onProgress` gets documents done and the total. Throws `CancellationError` when canceled.
    func run(
        workspaceID: UUID,
        options: Options = Options(),
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> Summary {
        var summary = Summary()
        guard let workspace = library.registry.workspace(id: workspaceID),
              library.state(for: workspaceID).hasScanned else {
            summary.notes.append("The workspace isn't listed yet. Try again in a moment.")
            return summary
        }
        guard let store = library.schemaStore(for: workspaceID),
              let schema = await Task.detached(operation: { try? store.load().schema }).value else {
            summary.notes.append("Fen can't read this workspace's document types.")
            return summary
        }
        let paths = library.state(for: workspaceID).snapshot.documents.map(\.relativePath)
        let documents = try await Self.read(paths, from: library.source(for: workspaceID))
        summary.scanned = documents.count
        let context = Context(
            workspace: workspace,
            schema: schema,
            documents: documents,
            runID: UUID(),
            waiting: Set(gate.pending(for: workspaceID)
                .map { $0.change.operation + "\u{0}" + $0.change.edit.primaryPath })
        )
        try await classify(context, options, &summary, onProgress: onProgress)
        try Task.checkCancellation()
        try await link(context, &summary)
        return summary
    }

    struct Context {
        let workspace: Workspace
        let schema: DocumentSchema
        let documents: [LinkDocument]
        let runID: UUID
        /// Operation and path of changes already waiting, so a second run doesn't queue them twice.
        let waiting: Set<String>
    }

    // MARK: - Reading

    private static func read(_ paths: [String], from source: LocalFolderSource?) async throws -> [LinkDocument] {
        guard let source else { return [] }
        let limit = maxBytes
        return try await Task.detached {
            let renderer = MarkdownRenderer()
            var documents: [LinkDocument] = []
            for path in paths {
                try Task.checkCancellation()
                guard let data = try? source.read(relativePath: path), data.count <= limit,
                      let text = String(data: data, encoding: .utf8) else { continue }
                let type = text.hasPrefix("---") ? DocumentProperties.typeName(in: renderer.peekFrontMatter(text)) : nil
                let title = MarkdownChunker.parse(text, path: path).title
                documents.append(LinkDocument(
                    path: path,
                    title: title,
                    text: text,
                    type: type?.isEmpty == true ? nil : type
                ))
            }
            return documents
        }.value
    }

    // MARK: - Types

    private func classify(
        _ context: Context,
        _ options: Options,
        _ summary: inout Summary,
        onProgress: (Int, Int) -> Void
    ) async throws {
        library.start()
        let search = library.search
        // A re-check ignores the examples, so a note's current type can't vote for itself.
        let examples = options.includeTyped ? [:] : await typedExamples(context, search)
        guard let classifier = await TypeClassifier.build(
            types: context.schema.types,
            floor: search.similarityFloor,
            examples: examples,
            embed: { await search.embedding(of: $0) }
        ) else {
            summary.notes.append("No on-device model is available, so Fen can't suggest types.")
            return
        }
        let candidates = context.documents.filter { $0.type == nil || options.includeTyped }
        var modelUsable = true
        for (done, document) in candidates.enumerated() {
            try Task.checkCancellation()
            onProgress(done, candidates.count)
            let excerpt = TypeClassifier.excerpt(of: document.text, path: document.path)
            guard let vector = await search.embedding(of: excerpt) else { continue }
            guard let proposal = await propose(
                classifier.verdict(for: vector), document, excerpt, context, options, &modelUsable, &summary
            ), proposal.type != document.type else { continue }
            submitType(proposal, for: document, excerpt, context, &summary)
        }
        onProgress(candidates.count, candidates.count)
    }

    /// Up to `examplesPerType` already-typed notes for each type, as vectors.
    private func typedExamples(_ context: Context, _ search: WorkspaceSearch) async -> [String: [[Float]]] {
        var examples: [String: [[Float]]] = [:]
        for document in context.documents {
            guard let type = document.type, examples[type, default: []].count < Self.examplesPerType,
                  let vector = await search.embedding(of: TypeClassifier.excerpt(
                      of: document.text,
                      path: document.path
                  ))
            else { continue }
            examples[type, default: []].append(vector)
        }
        return examples
    }

    private struct TypeProposal {
        let type: String
        let basis: ProposalBasis
        let provenance: Provenance
    }

    private func propose(
        _ verdict: TypeVerdict,
        _ document: LinkDocument,
        _ excerpt: String,
        _ context: Context,
        _ options: Options,
        _ modelUsable: inout Bool,
        _ summary: inout Summary
    ) async -> TypeProposal? {
        let device = Provenance(provider: "Fen", model: "on-device embedding", sources: [document.path])
        switch verdict {
        case .none:
            return nil
        case let .confident(best, margin):
            let confidence = min(Self.embeddingCeiling, 0.55 + Double(margin))
            let detail = "Closest to \(best.name): \(Self.describe(best.name, in: context.schema))"
            return TypeProposal(
                type: best.name,
                basis: ProposalBasis(method: "embedding", confidence: confidence, detail: detail, evidence: excerpt),
                provenance: device
            )
        case let .ambiguous(close):
            let names = close.map(\.name)
            if modelUsable, summary.modelCalls < options.maxModelCalls,
               let answer = await askModel(names, document, excerpt, context, &modelUsable, &summary) {
                return answer
            }
            guard let best = close.first else { return nil }
            return TypeProposal(
                type: best.name,
                basis: ProposalBasis(
                    method: "embedding",
                    confidence: Self.unsettledConfidence,
                    detail: "A close call between " + names.joined(separator: ", "),
                    evidence: excerpt
                ),
                provenance: device
            )
        }
    }

    /// Stage 2. `nil` when no provider may see this document, it fails, or it names none of `names`.
    private func askModel(
        _ names: [String],
        _ document: LinkDocument,
        _ excerpt: String,
        _ context: Context,
        _ modelUsable: inout Bool,
        _ summary: inout Summary
    ) async -> TypeProposal? {
        let url = library.fileURL(workspaceID: context.workspace.id, relativePath: document.path)
        guard InlineAIAccess.reason(library: library, service: service, fileURL: url, operation: "classify") == nil,
              let config = service.store.selected else {
            modelUsable = false
            return nil
        }
        let candidates = context.schema.types.filter { names.contains($0.name) }
        summary.modelCalls += 1
        do {
            var reply = ""
            let item = AIContextItem(workspaceID: context.workspace.id, label: document.path, text: excerpt)
            for try await piece in try service.send(
                prompt: ModelClassification.prompt(candidates: candidates),
                context: [item]
            ) {
                reply += piece
            }
            guard let choice = ModelClassification.parse(reply, candidates: candidates) else { return nil }
            return TypeProposal(
                type: choice.type,
                basis: ProposalBasis(
                    method: "model",
                    confidence: choice.confidence,
                    detail: "\(config.name) chose \(choice.type) between " + names.joined(separator: ", "),
                    evidence: excerpt
                ),
                provenance: Provenance(provider: config.name, model: config.model, sources: [document.path])
            )
        } catch {
            modelUsable = false
            summary.notes.append("The provider failed, so close calls wait for you: \(error.localizedDescription)")
            return nil
        }
    }

    private func submitType(
        _ proposal: TypeProposal,
        for document: LinkDocument,
        _: String,
        _ context: Context,
        _ summary: inout Summary
    ) {
        let edit = EditOperation.setFrontMatter(path: document.path, key: "type", value: proposal.type)
        submit(
            operation: "classify",
            documentType: proposal.type,
            edit: edit,
            proposal.basis,
            proposal.provenance,
            context,
            &summary
        ) { $0.typeProposals += 1 }
    }

    private static func describe(_ type: String, in schema: DocumentSchema) -> String {
        let text = schema.type(named: type)?.description ?? ""
        return text.isEmpty ? "its name" : text
    }

    // MARK: - Links

    private func link(_ context: Context, _ summary: inout Summary) async throws {
        let documents = context.documents
        let schema = context.schema
        let plan = await Task.detached { LinkPlanner.plan(documents: documents, schema: schema) }.value
        for line in plan.ambiguous.prefix(5) {
            summary.notes.append("Left alone: " + line)
        }
        for rewrite in plan.rewrites {
            try Task.checkCancellation()
            let weakest = rewrite.links.min { $0.method.confidence < $1.method.confidence }
            let detail = rewrite.links
                .map { "\($0.field): \($0.mention) → [[\($0.linkText)]] (\($0.method.rawValue))" }
                .joined(separator: "; ")
            let basis = ProposalBasis(
                method: weakest?.method.rawValue ?? "title",
                confidence: rewrite.confidence,
                detail: detail,
                evidence: Self.changedLines(rewrite)
            )
            submit(
                operation: "resolve-links",
                documentType: rewrite.type,
                edit: .replaceText(path: rewrite.path, find: rewrite.before, with: rewrite.after),
                basis,
                Provenance(
                    provider: "Fen",
                    model: "link resolver",
                    sources: Array(Set([rewrite.path] + rewrite.links.map(\.targetPath))).sorted()
                ),
                context,
                &summary
            ) { $0.linkProposals += 1 }
        }
        for stub in plan.stubs {
            try Task.checkCancellation()
            let basis = ProposalBasis(
                method: "field",
                confidence: Self.stubConfidence,
                detail: "\"\(stub.mention)\" in \(stub.field) matches no \(stub.type) document",
                evidence: "Mentioned in " + stub.mentionedIn.prefix(3).joined(separator: ", ")
            )
            submit(
                operation: "create-stub",
                documentType: stub.type,
                edit: .createFile(path: stub.path, content: stub.content),
                basis,
                Provenance(provider: "Fen", model: "link resolver", sources: stub.mentionedIn),
                context,
                &summary
            ) { $0.stubProposals += 1 }
        }
    }

    private static func changedLines(_ rewrite: LinkRewrite) -> String {
        let old = Set(rewrite.before.components(separatedBy: "\n"))
        return rewrite.after.components(separatedBy: "\n").filter { !old.contains($0) }.joined(separator: "\n")
    }

    // MARK: - Submitting

    private func submit(
        operation: String,
        documentType: String,
        edit: EditOperation,
        _ basis: ProposalBasis,
        _ provenance: Provenance,
        _ context: Context,
        _ summary: inout Summary,
        count: (inout Summary) -> Void
    ) {
        let path = edit.primaryPath
        guard !context.waiting.contains(operation + "\u{0}" + path) else { return }
        do {
            let change = try ProposedChange(
                workspaceID: context.workspace.id,
                runID: context.runID,
                operation: operation,
                documentType: documentType,
                edit: edit,
                scope: [path],
                baseHash: gate.contentHash(workspaceID: context.workspace.id, relativePath: path),
                invokedByUser: false,
                provenance: provenance,
                basis: basis
            )
            switch try gate.submit(change) {
            case .applied: summary.applied += 1
            case .pending: summary.queued += 1
            case .blocked:
                summary.blocked += 1
                return
            }
            count(&summary)
        } catch {
            summary.notes.append("\(path): \(error.localizedDescription)")
        }
    }
}
