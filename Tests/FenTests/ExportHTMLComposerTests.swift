@testable import FenCore
import Foundation
import Testing

/// Proves issue #31 rule 3 (N/A resiliency -- local write failures must be handleable, not
/// crash) and the composer + resolver working together end-to-end at the string/file level
/// (the real-flow proof lives in `ExportHTMLE2ETest.swift`).
struct ExportHTMLComposerTests {
    @Test @MainActor
    func composeForExportThenResolveProducesSelfContainedDocument() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportHTMLComposerTests-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: documentDirectory.appendingPathComponent("photo.png"))

        let renderer = MarkdownRenderer()
        let body = renderer.render("# Title\n\n![alt](photo.png)").html
        let preferences = try Preferences(
            defaults: #require(UserDefaults(suiteName: "export.composer.\(UUID().uuidString)"))
        )
        let composed = HTMLComposer().composeForExport(
            title: "Title",
            body: body,
            preferences: preferences,
            includeStyles: true,
            includeHighlighting: false
        )

        let resolved = ExportAssetResolver().resolve(
            html: composed, documentDirectory: documentDirectory, mode: .selfContained
        )

        #expect(resolved.html.contains("data:image/png;base64,"))
        #expect(resolved.html.contains("<title>Title</title>"))
    }

    @Test @MainActor
    func writingToAnUnwritableDestinationThrowsRatherThanCrashes() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportHTMLComposerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempRoot.path)
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: tempRoot.path)

        let destination = tempRoot.appendingPathComponent("export.html")
        let html = "<html></html>"

        #expect(throws: (any Error).self) {
            try html.write(to: destination, atomically: true, encoding: .utf8)
        }
    }
}
