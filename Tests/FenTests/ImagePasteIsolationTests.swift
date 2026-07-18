@testable import FenCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Harness gate 3 for issue #18: proves `ImageSidecarWriter`'s filename-picking holds no
/// static/module-level mutable state, per rule 1.1 -- constructs two independent sidecar
/// directories (mirroring two open document windows) and interleaves writes into each, asserting
/// neither document's numbering leaks into or skips because of the other's. Mirrors
/// `CopyButtonIsolationTests.swift`'s two-instance pattern, adapted to filesystem state instead
/// of DOM/pasteboard state.
struct ImagePasteIsolationTests {
    @Test
    func interleavedWritesAcrossTwoDocumentsNeverShareOrSkipNumbering() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImagePasteIsolationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let documentA = tempRoot.appendingPathComponent("notes-a.md")
        let documentB = tempRoot.appendingPathComponent("notes-b.md")
        let pngData = Data([0x89, 0x50, 0x4E, 0x47])

        let a1 = try #require(ImageSidecarWriter.write(data: pngData, contentType: .png, documentURL: documentA))
        let b1 = try #require(ImageSidecarWriter.write(data: pngData, contentType: .png, documentURL: documentB))
        let a2 = try #require(ImageSidecarWriter.write(data: pngData, contentType: .png, documentURL: documentA))
        let b2 = try #require(ImageSidecarWriter.write(data: pngData, contentType: .png, documentURL: documentB))

        #expect(a1 == "notes-a.assets/image-1.png")
        #expect(a2 == "notes-a.assets/image-2.png")
        #expect(b1 == "notes-b.assets/image-1.png")
        #expect(b2 == "notes-b.assets/image-2.png")

        let contentsA = try FileManager.default.contentsOfDirectory(
            at: tempRoot.appendingPathComponent("notes-a.assets"), includingPropertiesForKeys: nil
        )
        let contentsB = try FileManager.default.contentsOfDirectory(
            at: tempRoot.appendingPathComponent("notes-b.assets"), includingPropertiesForKeys: nil
        )
        #expect(contentsA.count == 2)
        #expect(contentsB.count == 2)
    }
}
