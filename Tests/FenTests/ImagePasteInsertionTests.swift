@testable import FenCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Unit tests for issue #18's shared insertion helpers -- `ImageSidecarWriter.write` and
/// `MarkdownFormatting.insertImageLink` -- called directly with plain `Data`/`UTType`/`String`/
/// `NSRange` values, no live `NSTextView`/`UITextView` involved (rule 5.2). Covers rules 2.1,
/// 2.2, 2.3, 3.1, and 4.1.
struct ImagePasteInsertionTests {
    private func makeTempDocumentDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePasteInsertionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Rule 2.1: non-image types are rejected, no file written

    @Test
    func nonImageContentTypeIsRejectedAndWritesNoFile() throws {
        let directory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")

        let result = ImageSidecarWriter.write(
            data: Data("plain text".utf8), contentType: .plainText, documentURL: documentURL
        )

        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes.assets").path))
    }

    // MARK: - Rule 2.2: write-path traversal guard

    @Test
    func sidecarDirectorySymlinkedOutsideTheDocumentDirectoryIsRejected() throws {
        let documentDirectory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: documentDirectory) }
        let outsideDirectory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: outsideDirectory) }

        // Pre-create "notes.assets" as a symlink pointing outside the document's own directory.
        // createDirectory(withIntermediateDirectories: true) succeeds on an already-existing
        // path (even reached via symlink), so without the resolvingSymlinksInPath guard, a write
        // would land in outsideDirectory instead of alongside the document.
        let sidecarPath = documentDirectory.appendingPathComponent("notes.assets")
        try FileManager.default.createSymbolicLink(at: sidecarPath, withDestinationURL: outsideDirectory)

        let documentURL = documentDirectory.appendingPathComponent("notes.md")
        let result = ImageSidecarWriter.write(
            data: Data([0x89, 0x50, 0x4E, 0x47]), contentType: .png, documentURL: documentURL
        )

        #expect(result == nil)
        let outsideContents = try FileManager.default.contentsOfDirectory(
            at: outsideDirectory, includingPropertiesForKeys: nil
        )
        #expect(outsideContents.isEmpty)
    }

    // MARK: - Rule 2.3: destination filename is always internally generated, bytes verbatim

    @Test
    func writtenFilenameIgnoresSourceNamingAndBytesAreVerbatim() throws {
        let directory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        // Bytes deliberately not a real PNG -- proves the write is a byte-verbatim copy with no
        // decode/validation step, matching rule 4.1's "no NSImage/UIImage round-trip" guarantee.
        let sourceBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00])

        let result = try #require(ImageSidecarWriter.write(
            data: sourceBytes, contentType: .png, documentURL: documentURL
        ))

        #expect(result == "notes.assets/image-1.png")
        let writtenBytes = try Data(contentsOf: directory.appendingPathComponent(result))
        #expect(writtenBytes == sourceBytes)
    }

    // MARK: - Rule 3.1: write failure declines cleanly

    @Test
    func directoryCreationFailureDeclinesWithoutThrowing() throws {
        let directory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        // Plant a plain file where the sidecar directory needs to go, so
        // FileManager.createDirectory fails with "file already exists at path".
        try Data().write(to: directory.appendingPathComponent("notes.assets"))

        let result = ImageSidecarWriter.write(
            data: Data([0x89, 0x50, 0x4E, 0x47]), contentType: .png, documentURL: documentURL
        )

        #expect(result == nil)
    }

    // MARK: - Rule 4.1: bounded filename search, no unbounded directory scan

    @Test
    func nextAvailableFilenameSkipsOnlyExistingNumbersWithNoUnboundedScan() throws {
        let directory = try makeTempDocumentDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        let sidecarDirectory = directory.appendingPathComponent("notes.assets")
        try FileManager.default.createDirectory(at: sidecarDirectory, withIntermediateDirectories: true)
        try Data().write(to: sidecarDirectory.appendingPathComponent("image-1.png"))
        try Data().write(to: sidecarDirectory.appendingPathComponent("image-2.png"))

        let result = try #require(ImageSidecarWriter.write(
            data: Data([0x89, 0x50, 0x4E, 0x47]), contentType: .png, documentURL: documentURL
        ))

        #expect(result == "notes.assets/image-3.png")
    }

    // MARK: - Rule 5.2: insertImageLink is a pure (text, selection) -> (text, selection) function

    @Test
    func insertImageLinkReplacesSelectionAndPlacesCaretAfterTheLink() {
        let result = MarkdownFormatting.insertImageLink(
            altText: "image-1.png",
            relativePath: "notes.assets/image-1.png",
            into: "before AFTER after",
            at: NSRange(location: 7, length: 5)
        )

        #expect(result.text == "before ![image-1.png](notes.assets/image-1.png) after")
        #expect(result.selection == NSRange(location: 7 + "![image-1.png](notes.assets/image-1.png)".count, length: 0))
    }

    @Test
    func insertImageLinkAtEmptySelectionInsertsAtCaret() {
        let result = MarkdownFormatting.insertImageLink(
            altText: "image-1.png",
            relativePath: "notes.assets/image-1.png",
            into: "hello world",
            at: NSRange(location: 5, length: 0)
        )

        #expect(result.text == "hello![image-1.png](notes.assets/image-1.png) world")
    }
}
