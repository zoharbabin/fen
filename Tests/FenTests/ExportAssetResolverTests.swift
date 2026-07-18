@testable import FenCore
import Foundation
import Testing

/// Proves issue #31 rules 4.1 and 4.2: `ExportAssetResolver`'s size and count caps, plus the
/// core self-contained/linked-assets rewriting behavior each mode is built around.
struct ExportAssetResolverTests {
    private func makeFixture() throws -> (documentDirectory: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportAssetResolverTests-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        return (documentDirectory, tempRoot)
    }

    private func writePNG(named name: String, byteCount: Int, in directory: URL) throws -> URL {
        // A minimal valid PNG signature followed by padding -- UTType lookup here is by file
        // extension, not by sniffing magic bytes, so the resolver only needs a plausible size.
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        var data = Data(signature)
        data.append(Data(repeating: 0, count: max(0, byteCount - signature.count)))
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    @Test @MainActor
    func selfContainedModeInlinesImageAsDataURI() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        _ = try writePNG(named: "image-1.png", byteCount: 100, in: documentDirectory)

        let html = #"<p><img src="image-1.png" alt=""></p>"#
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        #expect(result.html.contains("data:image/png;base64,"))
        #expect(!result.html.contains(#"src="image-1.png""#))
        #expect(result.assets.isEmpty, "self-contained mode never reports assets to copy")
    }

    @Test @MainActor
    func linkedAssetsModeRewritesPathAndReportsSourceFile() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let sourceFile = try writePNG(named: "image-1.png", byteCount: 100, in: documentDirectory)

        let html = #"<p><img src="image-1.png" alt=""></p>"#
        let result = ExportAssetResolver().resolve(
            html: html, documentDirectory: documentDirectory, mode: .linkedAssets(exportBaseName: "notes")
        )

        #expect(result.html.contains(#"src="notes.assets/image-1.png""#))
        #expect(
            result.assets ==
                [ExportResolvedAsset(relativePath: "notes.assets/image-1.png", sourceFileURL: sourceFile)]
        )
    }

    @Test @MainActor
    func linkedAssetsModeDedupesCollidingLeafNames() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        try FileManager.default.createDirectory(
            at: documentDirectory.appendingPathComponent("sub"), withIntermediateDirectories: true
        )
        _ = try writePNG(named: "image-1.png", byteCount: 100, in: documentDirectory)
        _ = try writePNG(named: "image-1.png", byteCount: 100, in: documentDirectory.appendingPathComponent("sub"))

        let html = #"<img src="image-1.png"><img src="sub/image-1.png">"#
        let result = ExportAssetResolver().resolve(
            html: html, documentDirectory: documentDirectory, mode: .linkedAssets(exportBaseName: "notes")
        )

        let relativePaths = result.assets.map(\.relativePath)
        #expect(relativePaths == ["notes.assets/image-1.png", "notes.assets/image-1-1.png"])
        #expect(Set(relativePaths).count == 2, "colliding leaf names must never overwrite each other")
    }

    @Test @MainActor
    func remoteAndDataURLReferencesAreLeftUnchanged() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let html = """
        <img src="https://example.com/a.png">
        <img src="data:image/png;base64,AAAA">
        """
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        #expect(result.html == html, "remote and data: URLs must never be rewritten or fetched")
    }

    @Test @MainActor
    func oversizedImageIsLeftUnrewritten() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        _ = try writePNG(
            named: "big.png",
            byteCount: ExportAssetResolver.maxInlineImageBytes + 1,
            in: documentDirectory
        )

        let html = #"<img src="big.png">"#
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        #expect(result.html == html, "an image over the size cap must keep its original relative src")
    }

    @Test @MainActor
    func missingImageIsLeftUnrewritten() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let html = #"<img src="missing.png">"#
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        #expect(result.html == html)
        #expect(result.assets.isEmpty)
    }

    @Test @MainActor
    func imageReferencesBeyondTheCountCapAreLeftUnrewritten() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        _ = try writePNG(named: "image-1.png", byteCount: 100, in: documentDirectory)

        let overCap = ExportAssetResolver.maxImageReferences + 5
        let html = String(repeating: #"<img src="image-1.png">"#, count: overCap)
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        let inlinedCount = result.html.components(separatedBy: "data:image/png;base64,").count - 1
        #expect(inlinedCount == ExportAssetResolver.maxImageReferences, "resolution must stop exactly at the cap")
        let unrewrittenCount = result.html.components(separatedBy: #"src="image-1.png""#).count - 1
        #expect(unrewrittenCount == 5, "references past the cap must keep their original relative src")
    }
}
