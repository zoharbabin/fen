@testable import FenCore
import Foundation
import Testing

/// End-to-end test for issue #31: drives the real export flow -- `DocumentHTMLExporter` render
/// through `HTMLExportController.write` -- against a fixture document with a real sidecar image,
/// then asserts the actual files landed on disk. Mirrors `ImagePasteE2ETest`'s shape: the modal
/// picker (`NSSavePanel`/`.fileExporter`) itself can't be driven headlessly, so this exercises
/// every step around it with real production types, not a call directly into
/// `ExportAssetResolver` (that's already covered by `ExportAssetResolverTests`).
@Suite("Exporting a document to HTML writes real HTML and asset files")
struct ExportHTMLE2ETest {
    private func makeFixture() throws -> (documentURL: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportHTMLE2ETest-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]).write(
            to: documentDirectory.appendingPathComponent("photo.png")
        )
        return (documentDirectory.appendingPathComponent("notes.md"), tempRoot)
    }

    @Test @MainActor
    func selfContainedExportWritesOneStandaloneHTMLFile() throws {
        let (documentURL, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let preferences =
            try Preferences(defaults: #require(UserDefaults(suiteName: "export.e2e.\(UUID().uuidString)")))

        let result = DocumentHTMLExporter().export(
            markdown: "---\ntitle: Notes\n---\n\n![photo](photo.png)",
            documentURL: documentURL,
            preferences: preferences,
            mode: .selfContained
        )

        let destination = tempRoot.appendingPathComponent("export.html")
        try HTMLExportController().write(result, to: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written.contains("data:image/png;base64,"))
        #expect(written.contains("<title>Notes</title>"))
        #expect(!FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("export.assets").path))
    }

    @Test @MainActor
    func linkedAssetsExportWritesHTMLPlusAssetsFolder() throws {
        let (documentURL, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let preferences =
            try Preferences(defaults: #require(UserDefaults(suiteName: "export.e2e.\(UUID().uuidString)")))

        let result = DocumentHTMLExporter().export(
            markdown: "# Notes\n\n![photo](photo.png)",
            documentURL: documentURL,
            preferences: preferences,
            mode: .linkedAssets(exportBaseName: "export")
        )

        let destination = tempRoot.appendingPathComponent("export.html")
        try HTMLExportController().write(result, to: destination)

        let written = try String(contentsOf: destination, encoding: .utf8)
        #expect(written.contains(#"src="export.assets/photo.png""#))
        let copiedAsset = tempRoot.appendingPathComponent("export.assets/photo.png")
        #expect(FileManager.default.fileExists(atPath: copiedAsset.path))
        #expect(try Data(contentsOf: copiedAsset) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }

    @Test @MainActor
    func linkedAssetsExportDocumentBuildsDirectoryFileWrapperForFileExporter() throws {
        let (documentURL, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let preferences =
            try Preferences(defaults: #require(UserDefaults(suiteName: "export.e2e.\(UUID().uuidString)")))

        let result = DocumentHTMLExporter().export(
            markdown: "# Notes\n\n![photo](photo.png)",
            documentURL: documentURL,
            preferences: preferences,
            mode: .linkedAssets(exportBaseName: "export")
        )

        let document = HTMLExportDocument(result: result, isDirectory: true)
        let wrapper = try document.makeFileWrapper()

        #expect(wrapper.isDirectory)
        let htmlWrapper = try #require(wrapper.fileWrappers?["index.html"])
        let htmlData = try #require(htmlWrapper.regularFileContents)
        #expect(String(data: htmlData, encoding: .utf8)?.contains(#"src="export.assets/photo.png""#) == true)

        let assetsFolder = try #require(wrapper.fileWrappers?["export.assets"])
        #expect(assetsFolder.isDirectory)
        let assetData = try #require(assetsFolder.fileWrappers?["photo.png"]?.regularFileContents)
        #expect(assetData == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))
    }
}
