import SwiftUI
import UniformTypeIdentifiers

/// Wraps an already-rendered `DocumentHTMLExporter.Result` for iOS's `.fileExporter` (issue #31)
/// -- `.fileExporter` needs a fully-prepared document before the user picks a destination, so the
/// render/compose/resolve work happens up front and this type only packages the result into a
/// `FileWrapper`. Self-contained mode writes a single HTML file; linked-assets mode writes a
/// directory (`index.html` + `.assets/`), since `.fileExporter` exports one item per call.
public struct HTMLExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] {
        []
    }

    public static var writableContentTypes: [UTType] {
        [.html, .folder]
    }

    private let result: DocumentHTMLExporter.Result
    private let isDirectory: Bool

    public init(result: DocumentHTMLExporter.Result, isDirectory: Bool) {
        self.result = result
        self.isDirectory = isDirectory
    }

    /// Never read back -- this document type only exists to be written out by `.fileExporter`.
    public init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try makeFileWrapper()
    }

    /// The actual wrapper-building logic, factored out of `fileWrapper(configuration:)` since
    /// `FileDocumentWriteConfiguration` has no accessible initializer for tests to construct --
    /// `ExportHTMLE2ETest` calls this directly to verify the real directory structure.
    func makeFileWrapper() throws -> FileWrapper {
        guard let htmlData = result.html.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        guard isDirectory else {
            return FileWrapper(regularFileWithContents: htmlData)
        }

        let htmlWrapper = FileWrapper(regularFileWithContents: htmlData)
        htmlWrapper.preferredFilename = "index.html"
        var children: [String: FileWrapper] = ["index.html": htmlWrapper]

        // Every `relativePath` is `<exportBaseName>.assets/<leaf>` (a single flat directory --
        // `ExportAssetResolver.uniqueLeafName` never nests), so grouping by the path's first
        // component reconstructs that one assets folder as its own directory `FileWrapper`.
        var assetsByFolder: [String: [String: FileWrapper]] = [:]
        for asset in result.assets {
            let components = asset.relativePath.split(separator: "/", maxSplits: 1)
            guard components.count == 2, let data = try? Data(contentsOf: asset.sourceFileURL) else { continue }
            let folderName = String(components[0])
            let leaf = String(components[1])
            let assetWrapper = FileWrapper(regularFileWithContents: data)
            assetWrapper.preferredFilename = leaf
            assetsByFolder[folderName, default: [:]][leaf] = assetWrapper
        }
        for (folderName, leaves) in assetsByFolder {
            let folderWrapper = FileWrapper(directoryWithFileWrappers: leaves)
            folderWrapper.preferredFilename = folderName
            children[folderName] = folderWrapper
        }

        return FileWrapper(directoryWithFileWrappers: children)
    }
}
