import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Cleans up the `fen-share-*` folders that hold the share sheet's `.md` copies. The system takes the
/// file when sharing starts and nothing tells us when it is done, so old folders are removed later.
public enum ShareTemporaryFiles {
    static let folderPrefix = "fen-share-"

    /// Removes `fen-share-*` folders in `directory` that were last changed more than `age` ago.
    public static func removeStale(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 3600,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            let changed = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let changed, now.timeIntervalSince(changed) > age {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}

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
            ShareTemporaryFiles.removeStale()
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(ShareTemporaryFiles.folderPrefix)\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(item.fileName)
            try Data(item.text.utf8).write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
        DataRepresentation(exportedContentType: .plainText) { Data($0.text.utf8) }
    }
}
