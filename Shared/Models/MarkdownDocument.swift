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
        return FileWrapper(regularFileWithContents: data)
    }

    /// Title derived from the document text (first heading or front matter title).
    var title: String? {
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
            if !trimmed.isEmpty, !trimmed.hasPrefix("---") {
                break
            }
        }
        return nil
    }
}
