import Foundation

/// A piece of text sent along with a prompt. `workspaceID` is set when it came from a workspace
/// file, which makes the gateway check that workspace's AI data access (issue #5).
public struct AIContextItem: Sendable, Equatable {
    public let workspaceID: UUID?
    /// Shown to the model, usually a relative path.
    public let label: String
    public let text: String

    public init(workspaceID: UUID?, label: String, text: String) {
        self.workspaceID = workspaceID
        self.label = label
        self.text = text
    }
}

public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    /// The model that ships with the OS. Runs inside Fen's process.
    case onDevice
    /// Ollama on this Mac (`localhost:11434`).
    case ollama
    /// Any OpenAI-compatible endpoint: LM Studio, OpenRouter, OpenAI, Ollama's compatible mode.
    case openAICompatible

    public var title: String {
        switch self {
        case .onDevice: "On-device model"
        case .ollama: "Ollama"
        case .openAICompatible: "OpenAI-compatible"
        }
    }
}

/// Generates text. Concrete providers are internal on purpose: features reach a model only through
/// `AIService`, which checks every workspace's AI data access first.
protocol AIProvider: Sendable {
    /// Where content goes. Decides which workspaces may use this provider.
    var destination: ModelDestination { get }
    /// Streams the answer in pieces. Cancel the consuming task to stop the request.
    func send(prompt: String, context: [AIContextItem]) -> AsyncThrowingStream<String, Error>
}

/// Turns a prompt and its context into the text a model sees.
enum AIPromptBuilder {
    static let instructions = """
    You help with notes and documents written in Markdown. \
    Files you are given appear in <document> tags. Use only them and the user's request.
    """

    /// Context first, then the request. File text is fenced by tags, not interpreted.
    static func userMessage(prompt: String, context: [AIContextItem]) -> String {
        guard !context.isEmpty else { return prompt }
        let documents = context.map { item in
            "<document path=\"\(escape(item.label))\">\n\(item.text)\n</document>"
        }
        return documents.joined(separator: "\n\n") + "\n\n" + prompt
    }

    private static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "\n", with: " ")
    }
}
