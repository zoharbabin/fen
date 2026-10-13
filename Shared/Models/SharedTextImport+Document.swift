import Foundation

public extension SharedTextImport {
    /// The new document for `raw`, or `nil` when there is nothing to import.
    static func document(from raw: String?) throws -> MarkdownDocument? {
        try text(from: raw).map { MarkdownDocument(text: $0) }
    }
}
