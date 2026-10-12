import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    }
}

/// A Markdown document that can be opened, edited, and saved on both macOS and iOS.
/// Conforms to ReferenceFileDocument (reference-type variant) for use with @Observable.
@Observable
public final class MarkdownDocument: ReferenceFileDocument, @unchecked Sendable {
    public typealias Snapshot = String

    var text: String

    /// The file URL this document was loaded from (set externally by the document group).
    public var fileURL: URL?

    public static var readableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    public static var writableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    public init(text: String = "") {
        self.text = text
    }

    /// The document a fresh `DocumentGroup(newDocument:)` should create -- the bundled welcome
    /// document the very first time (issue #37), blank every time after. `preferences` defaults
    /// to `.shared` since this always runs in-process on the real app, never across a process
    /// boundary the way the Quick Look extension does.
    public static func makeNew(preferences: Preferences = .shared) -> MarkdownDocument {
        MarkdownDocument(text: FirstRunContent.welcomeDocumentText(preferences: preferences) ?? "")
    }

    public required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? ""
    }

    public func snapshot(contentType _: UTType) throws -> String {
        var content = text
        if Preferences.shared.editorEnsuresNewlineAtEndOfFile, !content.hasSuffix("\n") {
            content += "\n"
        }
        return content
    }

    public func fileWrapper(snapshot: String, configuration _: WriteConfiguration) throws -> FileWrapper {
        guard let data = snapshot.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        // The file lands a moment after this returns. Enrich on save waits for a quiet period anyway.
        if let url = fileURL {
            Task { @MainActor in EnrichOnSave.shared.noteSaved(url) }
        }
        return FileWrapper(regularFileWithContents: data)
    }

    /// Title derived from the document text (first heading or front matter title).
    /// Reads one line at a time and stops at the first line that isn't blank, so a large note
    /// without a heading doesn't pay for splitting the whole text on every call.
    var title: String? {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let newline = text.rangeOfCharacter(from: .newlines, range: lineStart ..< text.endIndex)
            let trimmed = text[lineStart ..< (newline?.lowerBound ?? text.endIndex)]
                .trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
            if !trimmed.isEmpty, !trimmed.hasPrefix("---") {
                break
            }
            guard let newline else { break }
            lineStart = newline.upperBound
        }
        return nil
    }
}
