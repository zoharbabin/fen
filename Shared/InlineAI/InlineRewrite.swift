import Foundation

/// How much of the document the model sees for one call (issue #6).
public enum InlineScope: String, CaseIterable, Identifiable, Sendable {
    /// Only the selected text. The default.
    case selection
    /// The whole document, as background. Sent only when you choose it for that call.
    case document

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .selection: "Selection only"
        case .document: "Whole document"
        }
    }
}

/// Builds the request for "Ask AI" and cleans the reply (issue #6).
enum InlineRewrite {
    static let maxDocumentCharacters = 60000

    static let instructions = """
    Follow the instruction for the text in the <selection> tags. \
    Reply with only the new text that will replace it, in Markdown. \
    Add no preface, no explanation, and no code fence around the whole reply.
    """

    /// The prompt and the context items for one call. The context items carry the workspace, so the
    /// gateway checks its AI data access.
    static func request(
        instruction: String,
        scope: InlineScope,
        target: EditorTarget,
        document: String,
        workspaceID: UUID?,
        label: String
    ) throws -> (prompt: String, context: [AIContextItem]) {
        var prompt = "\(instructions)\n\nInstruction: \(instruction)\n\n"
        prompt += "<selection>\n\(target.text)\n</selection>"
        switch scope {
        case .selection:
            return (prompt, [AIContextItem(workspaceID: workspaceID, label: label, text: target.text)])
        case .document:
            guard document.count <= maxDocumentCharacters else { throw AIError.contextTooLarge }
            prompt += "\n\nThe full document is given above for background. Change only the selection."
            return (prompt, [AIContextItem(workspaceID: workspaceID, label: label, text: document)])
        }
    }

    /// The reply as the replacement text. A fence around the whole reply is removed, and the
    /// replacement keeps the spaces and line breaks that surrounded the original.
    static func cleaned(_ reply: String, original: String) -> String {
        var body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if !original.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```"),
           body.hasPrefix("```"), body.hasSuffix("```"), body.count > 6 {
            var lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            lines.removeFirst()
            lines.removeLast()
            body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !body.isEmpty else { return "" }
        let leading = String(original.prefix { $0.isWhitespace })
        let trailing = String(original.reversed().prefix { $0.isWhitespace }.reversed())
        return leading + body + trailing
    }
}
