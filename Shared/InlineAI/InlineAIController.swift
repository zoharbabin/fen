import Foundation
import Observation

/// "Ask AI" and "Enrich" on the text you are editing (issue #6).
///
/// You start every run, so the result goes into the editor as one edit. One Undo takes it back,
/// even when the answer streamed in. The text is never touched while the answer arrives. With
/// "Preview before applying" on, the edit waits for your click.
///
/// Nothing is sent without a provider (#4). The workspace's AI data access (#5) and its approval
/// mode (#140) are checked first. A file outside every workspace is shown to local providers only.
@MainActor @Observable
public final class InlineAIController {
    public enum Action: String, CaseIterable, Identifiable {
        case rewrite
        case enrich

        public var id: String {
            rawValue
        }

        public var title: String {
            self == .rewrite ? "Ask AI" : "Enrich"
        }
    }

    /// The edit that is ready to apply.
    public struct Proposal: Equatable {
        public let range: NSRange
        public let original: String
        public let replacement: String
        public let summary: String
    }

    public enum Phase: Equatable {
        case idle
        case working
        case preview(Proposal)
        case applied(String)
        /// Nothing to do, and why. Not an error.
        case notice(String)
        case failed(String)
    }

    public private(set) var phase = Phase.idle
    /// The answer as it streams in. Shown, never written to the document until it is complete.
    public private(set) var streamed = ""
    public private(set) var target: EditorTarget?
    public var action = Action.rewrite
    public var isPresented = false

    @ObservationIgnored private let library: WorkspaceLibrary
    @ObservationIgnored private let service: AIService
    @ObservationIgnored private let previewFirst: @MainActor () -> Bool
    @ObservationIgnored private var currentText: () -> String = { "" }
    @ObservationIgnored private var insert: (EditorInsertion) -> Void = { _ in }
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        library: WorkspaceLibrary = .shared,
        service: AIService = .shared,
        previewBeforeApplying: @escaping @MainActor () -> Bool = { Preferences.shared.inlineAIPreviewFirst }
    ) {
        self.library = library
        self.service = service
        previewFirst = previewBeforeApplying
    }

    /// Connects the editor: how to read its text now, and how to hand it an edit.
    func bind(currentText: @escaping () -> String, insert: @escaping (EditorInsertion) -> Void) {
        self.currentText = currentText
        self.insert = insert
    }

    public var isWorking: Bool {
        phase == .working
    }

    /// Opens the panel on the text at the caret or selection.
    public func present(target: EditorTarget?) {
        guard !isWorking else {
            isPresented = true
            return
        }
        self.target = target
        streamed = ""
        phase = .idle
        isPresented = true
    }

    // MARK: - Checks

    /// Why the action can't run for this file, or `nil` when it can.
    public func unavailableReason(fileURL: URL?, action: Action) -> String? {
        InlineAIAccess.reason(library: library, service: service, fileURL: fileURL, operation: action.rawValue)
    }

    // MARK: - Ask AI

    public func rewrite(instruction: String, scope: InlineScope, document: String, fileURL: URL?) {
        let trimmed = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target, !trimmed.isEmpty, !isWorking else { return }
        if let reason = unavailableReason(fileURL: fileURL, action: .rewrite) {
            phase = .failed(reason)
            return
        }
        let place = fileURL.flatMap { library.locate($0) }
        let built: (prompt: String, context: [AIContextItem])
        do {
            built = try InlineRewrite.request(
                instruction: trimmed,
                scope: scope,
                target: target,
                document: document,
                workspaceID: place?.workspace.id,
                label: place?.relativePath ?? "this document"
            )
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        begin {
            let reply = try await self.collect(prompt: built.prompt, context: built.context)
            let replacement = InlineRewrite.cleaned(reply, original: target.text)
            guard !replacement.isEmpty else { throw AIError.badResponse }
            self.finish(Proposal(
                range: target.range,
                original: target.text,
                replacement: replacement,
                summary: "Done. Undo takes it back."
            ))
        }
    }

    // MARK: - Enrich

    public func enrich(document _: String, fileURL: URL?) {
        guard let target, !isWorking else { return }
        if let reason = unavailableReason(fileURL: fileURL, action: .enrich) {
            phase = .failed(reason)
            return
        }
        let bullets = Enrichment.bullets(in: target.text)
        guard !bullets.isEmpty, let fileURL, let place = library.locate(fileURL) else {
            phase = .notice("Select the bullets you want to enrich.")
            return
        }
        begin {
            let result = try await EnrichmentPipeline.run(
                text: target.text,
                bullets: bullets,
                workspace: place.workspace,
                path: place.relativePath,
                library: self.library,
                service: self.service
            ) { self.streamed += $0 }
            switch result {
            case let .nothing(why):
                self.phase = .notice(why)
            case let .enriched(outcome, _):
                self.finish(Proposal(
                    range: target.range, original: target.text, replacement: outcome.text, summary: outcome.summary
                ))
            }
        }
    }

    // MARK: - Running

    private func begin(_ work: @escaping @MainActor () async throws -> Void) {
        streamed = ""
        phase = .working
        task = Task {
            do {
                try await work()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func collect(prompt: String, context: [AIContextItem]) async throws -> String {
        let stream = try service.send(prompt: prompt, context: context)
        for try await piece in stream {
            streamed += piece
        }
        try Task.checkCancellation()
        return streamed
    }

    private func finish(_ proposal: Proposal) {
        if previewFirst() {
            phase = .preview(proposal)
        } else {
            commit(proposal)
        }
    }

    // MARK: - Applying

    /// Applies the previewed edit.
    public func applyPreview() {
        if case let .preview(proposal) = phase {
            commit(proposal)
        }
    }

    public func discard() {
        phase = .idle
        streamed = ""
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if isWorking {
            phase = .idle
        }
    }

    private func commit(_ proposal: Proposal) {
        let edit = EditorInsertion(range: proposal.range, expected: proposal.original, text: proposal.replacement)
        guard edit.applies(to: currentText()) else {
            phase = .failed("The text changed while Fen was working. Nothing was changed.")
            return
        }
        insert(edit)
        phase = .applied(proposal.summary)
    }
}
