import Foundation
import Observation

/// Answers a question from your workspaces, with sources (issue #141).
///
/// It reads the search index (#35), sends the best passages to the selected provider (#4), and keeps
/// the answer and the passages it cites. It only reads: no file is written, and nothing is sent
/// when no provider is set up. A workspace whose AI data access does not allow the provider is left
/// out before search, and the controller lists it in `skipped`.
@MainActor @Observable
public final class AskController {
    public enum Phase: Equatable {
        case idle
        case searching
        case answering
        case done
        /// Nothing in scope supports an answer. The model was not asked, or said so.
        case notFound
        case failed(String)
    }

    public static let maxPassages = 8

    public private(set) var phase = Phase.idle
    public private(set) var answer = ""
    public private(set) var passages: [Passage] = []
    /// Names of workspaces in scope that were left out because their AI data access says no.
    public private(set) var skipped: [String] = []

    @ObservationIgnored private let library: WorkspaceLibrary
    @ObservationIgnored private let service: AIService
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(library: WorkspaceLibrary = .shared, service: AIService = .shared) {
        self.library = library
        self.service = service
    }

    public var isWorking: Bool {
        phase == .searching || phase == .answering
    }

    var reading: AnswerReading {
        AnswerReading.read(answer, passageCount: passages.count)
    }

    /// The answer with citations as links. Numbers that match no passage stay plain text.
    public var linkedAnswer: AttributedString {
        AnswerReading.linked(answer, passageCount: passages.count)
    }

    /// The passage a link from `linkedAnswer` points to.
    public func passage(for link: URL) -> Passage? {
        guard link.scheme == "fen-passage", let number = link.host.flatMap({ Int($0) }),
              passages.indices.contains(number - 1) else { return nil }
        return passages[number - 1]
    }

    /// The passages the answer cites, in the order it cites them.
    public var citedPassages: [Passage] {
        reading.cited.map { passages[$0 - 1] }
    }

    public var hasUnsupportedStatements: Bool {
        phase == .done && (reading.uncited > 0 || !reading.invalid.isEmpty)
    }

    public func ask(_ question: String, scope: WorkspaceScope) {
        cancel()
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        answer = ""
        passages = []
        skipped = []
        phase = .searching
        task = Task { await run(trimmed, scope: scope) }
    }

    public func cancel() {
        task?.cancel()
        task = nil
        if isWorking {
            phase = .idle
        }
    }

    private func run(_ question: String, scope: WorkspaceScope) async {
        let destination: ModelDestination
        do {
            destination = try service.destination()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }
        let workspaces = library.registry.workspaces
        let allowed = WorkspaceAccessPolicy.eligible(workspaces, scope: scope, destination: destination)
        let inScope = WorkspaceAccessPolicy.eligible(workspaces, scope: scope, destination: nil)
        skipped = inScope.filter { workspace in !allowed.contains { $0.id == workspace.id } }.map(\.name)

        let keywords = RelatedQuery.keywords(from: question)
        let results = await library.search.search(
            keywords.isEmpty ? question : keywords,
            meaning: question,
            anyWord: true,
            in: workspaces,
            scope: scope,
            destination: destination,
            limit: Self.maxPassages
        )
        let found = await AskPrompt.fitting(library.search.passages(for: results))
        guard !Task.isCancelled else { return }
        passages = found
        guard !found.isEmpty else {
            answer = AskPrompt.notFound
            phase = .notFound
            return
        }

        phase = .answering
        do {
            let stream = try service.send(
                prompt: AskPrompt.prompt(question: question),
                context: AskPrompt.context(for: found)
            )
            for try await piece in stream {
                answer += piece
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
            return
        }
        guard !Task.isCancelled else { return }
        if answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            phase = .failed(AIError.badResponse.localizedDescription)
        } else {
            phase = reading.isNotFound ? .notFound : .done
        }
    }
}
