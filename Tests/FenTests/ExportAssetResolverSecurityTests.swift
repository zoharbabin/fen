@testable import FenCore
import Foundation
import Testing

/// Proves issue #31 rules 2.1, 2.2, 2.3: `ExportAssetResolver` never shells out or evaluates
/// dynamic code, never fetches a remote URL, and never reads or reports a file that resolves
/// outside the document's own directory -- the same traversal guard
/// `PreviewSchemeHandler.resolvedFileURL` and `ImageSidecarWriter.write` already enforce.
struct ExportAssetResolverSecurityTests {
    private func sourceOfResolver() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ExportAssetResolverSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/Rendering/ExportAssetResolver.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test func resolverSourceContainsNoShellOutOrDynamicExecution() throws {
        let source = try sourceOfResolver()
        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval(", "URLSession"] {
            #expect(!source.contains(forbidden), "ExportAssetResolver.swift must not contain '\(forbidden)'")
        }
    }

    private func makeFixture() throws -> (documentDirectory: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportAssetResolverSecurityTests-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        return (documentDirectory, tempRoot)
    }

    @Test @MainActor
    func pathTraversalReferenceIsNeverInlined() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        // A real file that exists, but only reachable by escaping documentDirectory.
        let secretDirectory = tempRoot.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: secretDirectory.appendingPathComponent("private.png"))

        let html = #"<img src="../secret/private.png">"#
        let result = ExportAssetResolver().resolve(
            html: html,
            documentDirectory: documentDirectory,
            mode: .selfContained
        )

        #expect(result.html == html, "a src escaping the document directory must never be inlined")
        #expect(result.assets.isEmpty)
    }

    @Test @MainActor
    func symlinkEscapingDocumentDirectoryIsNeverReported() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let secretDirectory = tempRoot.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        let secretFile = secretDirectory.appendingPathComponent("private.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: secretFile)

        // A symlink planted inside documentDirectory but pointing outside it.
        let symlink = documentDirectory.appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: secretFile)

        let html = #"<img src="escape.png">"#
        let result = ExportAssetResolver().resolve(
            html: html, documentDirectory: documentDirectory, mode: .linkedAssets(exportBaseName: "notes")
        )

        #expect(result.html == html, "a symlink resolving outside the document directory must never be reported")
        #expect(result.assets.isEmpty)
    }

    @Test @MainActor
    func remoteURLIsNeverFetchedOrRewritten() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let html = #"<img src="http://example.com/tracking-pixel.png">"#
        let result = ExportAssetResolver().resolve(
            html: html, documentDirectory: documentDirectory, mode: .linkedAssets(exportBaseName: "notes")
        )

        #expect(result.html == html)
        #expect(result.assets.isEmpty)
    }
}
