import Foundation

/// Looks for notes that now disagree with each other (issue #94). It checks what changed since the
/// last run and the notes near it, not the whole workspace.
///
/// Tier 1 runs on the device: new passages are compared by meaning with the passages of nearby
/// notes, and a pair is kept only if it shows a mark of contradiction. Tier 2 asks the provider
/// about those pairs, only if one is set up and the workspace's AI data access lets it see both
/// notes. Without a provider, pairs with a strong mark are still flagged, with less confidence.
///
/// The run writes nothing to the workspace. What it learns goes to `~/.fen/workspaces/<id>/conflicts.json`.
@MainActor
struct ConflictRun {
    struct Options: Equatable {
        /// The most changed notes checked in one run. The rest wait for the next one.
        var maxDocuments = 40
        /// The most nearby notes compared with each changed note.
        var maxNeighbors = 8
        /// The most new passages of one note that are checked.
        var maxPassagesPerNote = 30
        /// The most pairs kept for the model in one run.
        var maxCandidates = 30
        /// The most pairs sent to the provider in one run.
        var maxModelCalls = 20
        var detector = ConflictDetector.Options()
        /// Also count the passages of the whole workspace, to report what a full pass would cost.
        var measureFullCorpus = false
    }

    struct Summary: Equatable {
        var changedNotes = 0
        var waitingNotes = 0
        var nearbyNotes = 0
        var newPassages = 0
        var detection = DetectionStats()
        var modelCalls = 0
        var flagged = 0
        var closed = 0
        var usedGit = false
        /// Passages in the whole workspace. Set only when `Options.measureFullCorpus` is on.
        var corpusPassages = 0
        var notes: [String] = []

        /// Passage pairs a pass over the whole workspace would compare.
        var fullCorpusPairs: Int {
            corpusPassages * (corpusPassages - 1) / 2
        }

        var text: String {
            if changedNotes == 0, !notes.isEmpty {
                return notes.joined(separator: "\n")
            }
            var lines: [String] = []
            if changedNotes == 0 {
                lines.append("No notes changed since the last check.")
            } else {
                lines.append("Checked \(changedNotes) changed notes against \(nearbyNotes) nearby ones.")
                lines
                    .append(
                        "Compared \(detection.compared) passage pairs. \(detection.candidates) were worth a closer look."
                    )
            }
            if modelCalls > 0 {
                lines.append("Asked your model about \(modelCalls).")
            }
            if flagged > 0 {
                lines.append("Found \(flagged) possible conflicts.")
            } else if changedNotes > 0 {
                lines.append("Found no conflicts.")
            }
            if closed > 0 {
                lines.append("\(closed) earlier flags no longer apply.")
            }
            if waitingNotes > 0 {
                lines.append("\(waitingNotes) more changed notes wait for the next check.")
            }
            return (lines + notes.prefix(3)).joined(separator: "\n")
        }
    }

    /// The most bytes of a note that is read. Larger files are skipped.
    static let maxBytes = SchemaMigration.maxBytes
    /// What a pair with a mark is worth when no model judged it. Under any auto-approve threshold.
    static let signalCeiling = 0.5

    let library: WorkspaceLibrary
    let service: AIService
    let gate: WriteGate
    var git: GitTool? = GitTool.locate()

    /// `onProgress` gets notes done and the total. Throws `CancellationError` when canceled, and then
    /// nothing is saved, so the next run starts from the same point.
    func run(
        workspaceID: UUID,
        options: Options = Options(),
        onProgress: (Int, Int) -> Void = { _, _ in }
    ) async throws -> Summary {
        var summary = Summary()
        guard let workspace = library.registry.workspace(id: workspaceID),
              library.state(for: workspaceID).hasScanned,
              let source = library.source(for: workspaceID),
              let root = try? library.registry.rootURL(for: workspaceID) else {
            summary.notes.append("The workspace isn't listed yet. Try again in a moment.")
            return summary
        }
        library.start()
        let search = library.search
        guard await search.embedding(of: "check") != nil else {
            summary.notes.append("No on-device model is available, so Fen can't compare notes by meaning.")
            return summary
        }
        let store = ConflictStore(file: gate.home.conflictsFile(id: workspaceID))
        var state = store.load()
        let files = library.state(for: workspaceID).snapshot.documents
        let paths = files.map(\.relativePath)

        let delta = await ConflictDeltaFinder.find(
            root: root, paths: paths, state: state, git: git,
            hash: { path in (try? source.read(relativePath: path)).map { ContentHash.of($0) } }
        )
        summary.usedGit = delta.usedGit
        let modified = Dictionary(files.map { ($0.relativePath, $0.modified) }) { first, _ in first }
        let ordered = delta.changed.sorted { (modified[$0] ?? .distantPast) > (modified[$1] ?? .distantPast) }
        let batch = Array(ordered.prefix(options.maxDocuments))
        summary.changedNotes = batch.count
        summary.waitingNotes = ordered.count - batch.count

        let changedNotes = try await Self.read(batch, from: source)
        var detector = ConflictDetector(options: options.detector) { await search.embedding(of: $0) }
        var found: [ConflictCandidate] = []
        var nearby: Set<String> = []
        for (done, path) in batch.enumerated() {
            try Task.checkCancellation()
            onProgress(done, batch.count)
            guard let note = changedNotes[path] else { continue }
            let known = Set(state.files[path]?.passages ?? [])
            let fresh = Array(ConflictPassage.split(note.text).filter { !known.contains($0.shortHash) }
                .prefix(options.maxPassagesPerNote))
            guard !fresh.isEmpty else { continue }
            summary.newPassages += fresh.count
            let neighborPaths = await neighbors(of: path, fresh: fresh, workspace: workspace, paths: paths, options)
            nearby.formUnion(neighborPaths)
            let texts = try await Self.read(neighborPaths, from: source)
            found += await detector.candidates(
                changed: fresh,
                in: path,
                neighbors: neighborPaths.compactMap { path in texts[path].map { (path: path, text: $0.text) } }
            )
        }
        onProgress(batch.count, batch.count)
        summary.nearbyNotes = nearby.count
        summary.detection = detector.stats
        if options.measureFullCorpus {
            summary.corpusPassages = try await Self.countPassages(paths, from: source)
        }

        let candidates = Self.keep(found, excluding: state.flags, limit: options.maxCandidates)
        let flags = try await judge(candidates, workspace: workspace, options, &summary)
        summary.flagged = flags.count

        try await settle(
            &state,
            with: flags,
            notes: changedNotes,
            paths: paths,
            source: source,
            head: delta.head,
            &summary
        )
        try store.save(state)
        return summary
    }

    // MARK: - Neighborhood

    private func neighbors(
        of path: String,
        fresh: [ConflictPassage],
        workspace: Workspace,
        paths: [String],
        _ options: Options
    ) async -> [String] {
        let search = library.search
        var linked: [String] = []
        if let index = search.indexes[workspace.id], let links = try? await index.linkedPaths(of: path) {
            linked = (links.outgoing.union(links.incoming)).sorted()
        }
        var similar: [String] = []
        for passage in fresh.prefix(3) {
            for suggestion in await search.related(to: passage.text, from: path, in: workspace, limit: 4) {
                similar.append(suggestion.relativePath)
            }
        }
        return ConflictNeighborhood.order(
            of: path,
            linked: linked,
            similar: similar,
            folder: ConflictNeighborhood.folderMates(of: path, in: paths),
            limit: options.maxNeighbors
        )
    }

    /// The best `limit` pairs not already flagged, each pair once.
    static func keep(_ found: [ConflictCandidate], excluding flags: [ConflictFlag], limit: Int) -> [ConflictCandidate] {
        var seen = Set(flags.map(\.pairKey))
        var kept: [ConflictCandidate] = []
        for candidate in found.sorted(by: { $0.rank > $1.rank }) where kept.count < limit {
            let key = [candidate.changed.hash, candidate.other.hash].sorted().joined(separator: "+")
            if seen.insert(key).inserted {
                kept.append(candidate)
            }
        }
        return kept
    }

    // MARK: - Tier 2

    private func judge(
        _ candidates: [ConflictCandidate],
        workspace: Workspace,
        _ options: Options,
        _ summary: inout Summary
    ) async throws -> [ConflictFlag] {
        var flags: [ConflictFlag] = []
        var modelUsable = true
        for candidate in candidates {
            try Task.checkCancellation()
            if modelUsable, summary.modelCalls < options.maxModelCalls {
                switch await ask(candidate, workspace, &modelUsable, &summary) {
                case .none:
                    break
                case let .some(verdict) where !verdict.conflict:
                    continue
                case let .some(verdict):
                    flags.append(Self.flag(candidate, verdict: verdict))
                    continue
                }
            }
            if let flag = Self.flag(candidate, signalsOnly: ()) {
                flags.append(flag)
            }
        }
        return flags
    }

    /// `nil` when no provider may see both notes, it fails, or its reply isn't JSON in the shape asked for.
    private func ask(
        _ candidate: ConflictCandidate,
        _ workspace: Workspace,
        _ modelUsable: inout Bool,
        _ summary: inout Summary
    ) async -> ModelConflictJudge.Verdict? {
        let urls = [candidate.changed.path, candidate.other.path].map {
            library.fileURL(workspaceID: workspace.id, relativePath: $0)
        }
        for url in urls {
            if let reason = InlineAIAccess.reason(
                library: library,
                service: service,
                fileURL: url,
                operation: "conflicts"
            ) {
                modelUsable = false
                if !summary.notes.contains(where: { $0.hasPrefix("No model") }) {
                    summary.notes.append("No model checked these pairs: \(reason)")
                }
                return nil
            }
        }
        summary.modelCalls += 1
        do {
            var reply = ""
            let items = [
                AIContextItem(
                    workspaceID: workspace.id,
                    label: "FIRST (\(candidate.changed.path))",
                    text: candidate.changed.text
                ),
                AIContextItem(
                    workspaceID: workspace.id,
                    label: "SECOND (\(candidate.other.path))",
                    text: candidate.other.text
                ),
            ]
            for try await piece in try service.send(prompt: ModelConflictJudge.prompt, context: items) {
                reply += piece
            }
            return ModelConflictJudge.parse(reply)
        } catch {
            modelUsable = false
            summary.notes.append("The provider failed, so pairs are flagged without it: \(error.localizedDescription)")
            return nil
        }
    }

    private static func flag(_ candidate: ConflictCandidate, verdict: ModelConflictJudge.Verdict) -> ConflictFlag {
        let stale: String? = switch verdict.outdated {
        case "first": "changed"
        case "second": "other"
        case "both": "both"
        default: nil
        }
        return ConflictFlag(
            id: UUID(),
            changed: candidate.changed,
            other: candidate.other,
            confidence: verdict.confidence,
            method: "model",
            explanation: verdict.explanation.isEmpty ? candidate.signals.reasons.joined(separator: "; ") : verdict
                .explanation,
            created: Date(),
            status: .open,
            resolution: nil,
            staleSide: stale
        )
    }

    /// A flag from the marks alone. `nil` when the pair showed none, so a near copy with no mark is not flagged.
    private static func flag(_ candidate: ConflictCandidate, signalsOnly _: Void) -> ConflictFlag? {
        guard candidate.signals.score >= ConflictDetector.Options().minSignal else { return nil }
        return ConflictFlag(
            id: UUID(),
            changed: candidate.changed,
            other: candidate.other,
            confidence: min(signalCeiling, 0.2 + 0.4 * candidate.signals.score),
            method: "signals",
            explanation: "May contradict: " + candidate.signals.reasons.joined(separator: "; "),
            created: Date(),
            status: .open,
            resolution: nil,
            staleSide: nil
        )
    }

    // MARK: - State

    /// Records what this run saw and drops flags that no longer match the text.
    private func settle(
        _ state: inout ConflictState,
        with flags: [ConflictFlag],
        notes: [String: Note],
        paths: [String],
        source: LocalFolderSource,
        head: String?,
        _ summary: inout Summary
    ) async throws {
        for (path, note) in notes {
            state.files[path] = ConflictState.FileRecord(
                hash: note.hash,
                passages: ConflictPassage.split(note.text).map(\.shortHash)
            )
        }
        let present = Set(paths)
        state.files = state.files.filter { present.contains($0.key) }

        let flagPaths = Set((state.flags + flags).flatMap { [$0.changed.path, $0.other.path] })
        let texts = try await Self.read(Array(flagPaths), from: source)
        let before = state.flags.count
        state.flags = state.flags.filter { flag in
            // A fix in progress or done stays until you clear it, so undoing the fix can reopen the flag.
            if flag.resolution != nil {
                return true
            }
            let location = flag.locate { texts[$0]?.text }
            return location.changed != .stale && location.other != .stale
        }
        summary.closed = before - state.flags.count
        state.flags += flags
        if summary.waitingNotes == 0 {
            state.commit = head
        }
        state.lastRun = Date()
    }

    // MARK: - Reading

    struct Note: Sendable {
        let text: String
        /// Hash of the file's bytes, as `ConflictDeltaFinder` computes it.
        let hash: String
    }

    private static func read(_ paths: [String], from source: LocalFolderSource) async throws -> [String: Note] {
        let limit = maxBytes
        return try await Task.detached {
            var notes: [String: Note] = [:]
            for path in paths {
                try Task.checkCancellation()
                guard let data = try? source.read(relativePath: path), data.count <= limit,
                      let text = String(data: data, encoding: .utf8) else { continue }
                notes[path] = Note(text: text, hash: ContentHash.of(data))
            }
            return notes
        }.value
    }

    private static func countPassages(_ paths: [String], from source: LocalFolderSource) async throws -> Int {
        let notes = try await read(paths, from: source)
        return notes.values.reduce(0) { $0 + ConflictPassage.split($1.text).count }
    }
}
