import Foundation

/// Why an AI request or a provider setup failed. Messages are written for the person using Fen.
public enum AIError: Error, Equatable, LocalizedError {
    case notConfigured
    case invalidEndpoint(String)
    /// A remote endpoint over plain `http`. Keys and content would cross the network unencrypted.
    case insecureEndpoint(host: String)
    case notLoopback(host: String)
    case missingModel
    case unknownWorkspace
    case workspaceDisallows(workspace: String, access: AIDataAccess, destination: ModelDestination)
    case http(status: Int, message: String)
    case badResponse
    case redirectRefused
    case systemModelUnavailable(String)
    case contextTooLarge

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "No AI provider is set up. Add one in Settings, AI."
        case let .invalidEndpoint(text):
            "\"\(text)\" is not a valid address. Use a full URL such as http://localhost:11434."
        case let .insecureEndpoint(host):
            "\(host) is not on this device or your local network, so it needs https."
        case let .notLoopback(host):
            "Ollama must run on this Mac. \(host) is not a local address."
        case .missingModel:
            "Enter a model name."
        case .unknownWorkspace:
            "That content belongs to a workspace Fen doesn't know. Nothing was sent."
        case let .workspaceDisallows(workspace, access, destination):
            switch (access, destination) {
            case (.none, _):
                "\(workspace) is set to AI data access: None. Nothing was sent."
            default:
                "\(workspace) allows local providers only, and this provider is not local. Nothing was sent."
            }
        case let .http(status, message):
            message.isEmpty ? "The provider answered with HTTP \(status)." : "HTTP \(status): \(message)"
        case .badResponse:
            "The provider's answer could not be read."
        case .redirectRefused:
            "The provider tried to send Fen to another address. Fen does not follow redirects."
        case let .systemModelUnavailable(reason):
            reason
        case .contextTooLarge:
            "The text is too long for this model. Select less text and try again."
        }
    }
}
