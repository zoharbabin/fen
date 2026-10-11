import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// What the iOS share sheet sends for the open document (issue #43). Apps that take files get a real
/// `.md` file. Apps that only take text, such as Messages, get the Markdown as text.
struct SharedMarkdown: Transferable {
    let name: String
    let text: String

    init(name: String, text: String) {
        self.name = name
        self.text = text
    }

    init(document: MarkdownDocument) {
        let fileBase = document.fileURL?.deletingPathExtension().lastPathComponent
        self.init(name: fileBase ?? document.title ?? "", text: document.text)
    }

    /// The name of the file you share: the name made safe, then `.md`.
    var fileName: String {
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ").trimmingCharacters(in: edges)
        return (cleaned.isEmpty ? "Untitled" : String(cleaned.prefix(80))) + ".md"
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .markdown) { item in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("fen-share-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(item.fileName)
            try Data(item.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        ProxyRepresentation(exporting: \.text)
    }
}
