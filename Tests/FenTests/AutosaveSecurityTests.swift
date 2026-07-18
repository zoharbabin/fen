@testable import FenCore
import Foundation
import Testing

/// Proves rules 2.1 and 2.2 from issue #22's spec (github.com/zoharbabin/fen/issues/22): a
/// recovery entry's identity is always a hash of the document's resolved absolute path (never a
/// literal or concatenated path string), taken after symlink resolution so two paths that
/// resolve to the same real file share one recovery entry -- the same ordering mistake issue
/// #18's Phase 4 caught and fixed for `ImageSidecarWriter`'s traversal guard -- and nothing in
/// the implementation relaxes the recovery directory's inherited permissions.
struct AutosaveSecurityTests {
    private func sourceOfController() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // AutosaveSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/Models/AutosaveController.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test func controllerSourceContainsNoShellOutOrDynamicExecution() throws {
        let source = try sourceOfController()
        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval(", "URLSession", "setAttributes", "chmod"] {
            #expect(!source.contains(forbidden), "AutosaveController.swift must not contain '\(forbidden)'")
        }
    }

    @Test @MainActor
    func twoPathsResolvingToTheSameRealFileShareOneRecoveryIdentity() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutosaveSecurityTests-\(UUID().uuidString)")
        let realDirectory = tempRoot.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let realFile = realDirectory.appendingPathComponent("notes.md")
        try "content".write(to: realFile, atomically: true, encoding: .utf8)

        let symlinkDirectory = tempRoot.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkDirectory, withDestinationURL: realDirectory)
        let aliasedFile = symlinkDirectory.appendingPathComponent("notes.md")

        let identityViaRealPath = AutosaveController.pathIdentity(for: realFile)
        let identityViaSymlinkedPath = AutosaveController.pathIdentity(for: aliasedFile)

        #expect(
            identityViaRealPath == identityViaSymlinkedPath,
            "the same real file reached through a symlinked directory must hash to the same recovery identity"
        )
    }

    @Test @MainActor
    func differentRealFilesNeverShareARecoveryIdentity() {
        let identityA = AutosaveController.pathIdentity(for: URL(fileURLWithPath: "/tmp/a.md"))
        let identityB = AutosaveController.pathIdentity(for: URL(fileURLWithPath: "/tmp/b.md"))
        #expect(identityA != identityB)
    }
}
