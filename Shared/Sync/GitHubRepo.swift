import Foundation

/// A repository on github.com (issue #60). Only github.com is accepted, so a token can't be sent anywhere else.
public struct GitHubRepo: Equatable, Hashable, Sendable {
    public let owner: String
    public let name: String

    public var cloneURL: URL {
        URL(string: "https://github.com/\(owner)/\(name).git")!
    }

    /// The Keychain account for this repository's token.
    public var tokenAccount: String {
        "github.com/\(owner)/\(name)".lowercased()
    }

    public var title: String {
        "\(owner)/\(name)"
    }

    /// Reads `owner/repo`, `https://github.com/owner/repo(.git)` and `git@github.com:owner/repo.git`.
    /// Anything else, including other hosts and extra path parts, gives `nil`.
    public static func parse(_ text: String) -> GitHubRepo? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://github.com/", "git@github.com:", "ssh://git@github.com/"]
            where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
        }
        if value.hasSuffix("/") {
            value.removeLast()
        }
        if value.hasSuffix(".git") {
            value.removeLast(4)
        }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, validOwner(parts[0]), validName(parts[1]) else { return nil }
        return GitHubRepo(owner: parts[0], name: parts[1])
    }

    private static func validOwner(_ text: String) -> Bool {
        guard (1 ... 39).contains(text.count), !text.hasPrefix("-"), !text.hasSuffix("-") else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    private static func validName(_ text: String) -> Bool {
        guard (1 ... 100).contains(text.count), text != ".", text != ".." else { return false }
        return text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}

/// Which tokens Fen accepts (issue #60). A token must be scoped, never a broad one.
public enum GitHubToken {
    public enum Problem: Error, Equatable, LocalizedError {
        case empty
        case classic
        case unknown

        public var errorDescription: String? {
            switch self {
            case .empty:
                "Paste a token."
            case .classic:
                "That is a classic token. It can reach every repository you have. "
                    + "Create a fine-grained token for this one repository, with Contents set to Read and write."
            case .unknown:
                "That doesn't look like a GitHub token. A fine-grained token starts with github_pat_."
            }
        }
    }

    /// Fine-grained personal tokens and GitHub App tokens.
    static let accepted = ["github_pat_", "ghu_", "ghs_"]

    public static func validate(_ text: String) throws -> String {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw Problem.empty }
        if token.hasPrefix("ghp_") || token.hasPrefix("gho_") {
            throw Problem.classic
        }
        guard accepted.contains(where: token.hasPrefix),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else { throw Problem.unknown }
        return token
    }

    /// Why `validate` refuses `text`, in words for the form.
    public static func validationMessage(_ text: String) -> String? {
        do {
            _ = try validate(text)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    public static let service = "app.fen.github"
}
