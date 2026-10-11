import Foundation

/// What the Properties panel shows for one document, and the text each edit produces (issue #7).
/// It has no state and no UI, so the rules are testable without a window.
public struct PropertiesSnapshot: Sendable {
    public struct Row: Identifiable, Sendable, Equatable {
        public let field: SchemaField
        /// The value as text for a form. Empty when the document has none.
        public let value: String
        /// `false` when the value is a block or a mapping. The panel shows it but doesn't edit it.
        public let isEditable: Bool

        public var id: String {
            field.name
        }

        public var isMissingRequired: Bool {
            field.required && value.isEmpty
        }
    }

    public let typeName: String?
    public let type: DocumentType?
    public let rows: [Row]
    public let hints: [SchemaHint]
    private let text: String

    /// Hidden fields are left out of `rows`. They stay in the file.
    public init(text: String, schema: DocumentSchema) {
        self.text = text
        let front = text.hasPrefix("---") ? MarkdownRenderer().peekFrontMatter(text) : nil
        typeName = DocumentProperties.typeName(in: front)
        type = typeName.flatMap { schema.type(named: $0) }
        hints = SchemaHints.hints(for: front, in: schema)
        rows = (type?.fields ?? []).filter { !$0.hidden }.map { field in
            let value = front?[field.name]
            return Row(
                field: field,
                value: DocumentProperties.text(for: value),
                isEditable: DocumentProperties.isEditable(value)
            )
        }
    }

    /// `true` when the panel has something to show.
    public var isRelevant: Bool {
        type != nil || !hints.isEmpty
    }

    /// The document text with `field` set to what you typed. Clearing the field removes its line.
    /// Throws when the input doesn't fit the kind of field, and the text is unchanged then.
    public func setting(_ input: String, for field: SchemaField) throws -> String {
        if let yaml = try DocumentProperties.yaml(for: field, input: input) {
            return try FrontMatterEditor.setRaw(key: field.name, yaml: yaml, in: text)
        }
        return try FrontMatterEditor.removeKey(field.name, in: text)
    }

    /// The document text with a hint's fix applied.
    public func applying(_ fix: SchemaHint.Fix) throws -> String {
        switch fix {
        case let .setType(name):
            try FrontMatterEditor.setRaw(key: "type", yaml: FrontMatterEditor.scalar(name), in: text)
        case let .renameKey(from, to):
            try FrontMatterEditor.renameKey(from: from, to: to, in: text)
        }
    }
}

public extension EditorInsertion {
    /// The smallest edit that turns `old` into `new`: it cuts the shared start and end. The editor
    /// applies it like typing, so the caret, scroll position, and undo stack stay as they are.
    /// Returns `nil` when the texts are equal.
    static func minimalEdit(from old: String, to new: String) -> EditorInsertion? {
        guard old != new else { return nil }
        let oldChars = Array(old)
        let newChars = Array(new)
        var prefix = 0
        while prefix < min(oldChars.count, newChars.count), oldChars[prefix] == newChars[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < min(oldChars.count, newChars.count) - prefix,
              oldChars[oldChars.count - 1 - suffix] == newChars[newChars.count - 1 - suffix] {
            suffix += 1
        }
        let head = String(oldChars[..<prefix])
        let removed = String(oldChars[prefix ..< oldChars.count - suffix])
        let added = String(newChars[prefix ..< newChars.count - suffix])
        let location = (head as NSString).length
        return EditorInsertion(
            range: NSRange(location: location, length: (removed as NSString).length),
            expected: removed,
            text: added
        )
    }
}
