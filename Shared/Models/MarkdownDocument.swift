import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static var markdown: UTType {
        UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
    }
}

/// A Markdown document that can be opened, edited, and saved on both macOS and iOS.
/// Conforms to FileDocument for SwiftUI document-based app support.
@Observable
final class MarkdownDocument: FileDocument {
    var text: String

    /// The file URL this document was loaded from (set externally by the document group).
    var fileURL: URL?

    static var readableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    static var writableContentTypes: [UTType] {
        [.markdown, .plainText]
    }

    init(text: String = "") {
        self.text = text
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        var content = text
        // Ensure newline at end of file
        if Preferences.shared.editorEnsuresNewlineAtEndOfFile && !content.hasSuffix("\n") {
            content += "\n"
        }
        guard let data = content.data(using: .utf8) else {
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
            if !trimmed.isEmpty && !trimmed.hasPrefix("---") {
                break
            }
        }
        return nil
    }
}
