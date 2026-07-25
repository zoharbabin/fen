@testable import FenCore
import Foundation
import Testing

/// Proves issue #49 rule 2: the Quick Look extension introduces zero new network access and
/// never bypasses `ExportAssetResolver`'s existing path-traversal guard (mirrors
/// `ExportAssetResolverSecurityTests.swift`'s source-scan + traversal-attempt pattern) --
/// `QuickLookPreviewRenderer` renders in `.selfContained` mode, so every asset reference is
/// resolved through that same guard, never a separate filesystem-access path.
struct QuickLookSecurityTests {
    private func sourceOfRenderer() throws -> String {
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuickLookSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Shared/QuickLook/QuickLookPreviewRenderer.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    @Test func rendererSourceContainsNoShellOutDynamicExecutionOrNetworking() throws {
        let source = try sourceOfRenderer()
        for forbidden in ["Process(", "/bin/sh", "NSAppleScript", "eval(", "URLSession"] {
            #expect(!source.contains(forbidden), "QuickLookPreviewRenderer.swift must not contain '\(forbidden)'")
        }
    }

    @Test func rendererAlwaysUsesSelfContainedModeNeverLinkedAssets() throws {
        // .linkedAssets writes a sidecar folder next to the previewed file -- a Quick Look
        // extension has no destination to write into and must never attempt to (rule 4.1 of
        // issue #31 already forbids writes outside an explicit export flow).
        let source = try sourceOfRenderer()
        #expect(source.contains(".selfContained"))
        #expect(!source.contains(".linkedAssets"))
    }

    private func makeFixture() throws -> (documentDirectory: URL, tempRoot: URL) {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickLookSecurityTests-\(UUID().uuidString)")
        let documentDirectory = tempRoot.appendingPathComponent("doc", isDirectory: true)
        try FileManager.default.createDirectory(at: documentDirectory, withIntermediateDirectories: true)
        return (documentDirectory, tempRoot)
    }

    @Test @MainActor
    func pathTraversalImageReferenceIsNeverInlinedIntoThePreview() throws {
        let (documentDirectory, tempRoot) = try makeFixture()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let secretDirectory = tempRoot.appendingPathComponent("secret", isDirectory: true)
        try FileManager.default.createDirectory(at: secretDirectory, withIntermediateDirectories: true)
        let secretBytes = Data([0x89, 0x50, 0x4E, 0x47, 0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x01, 0x02, 0x03])
        try secretBytes.write(to: secretDirectory.appendingPathComponent("private.png"))

        let fileURL = documentDirectory.appendingPathComponent("note.md")
        try #"""
        # Note

        ![leak](../secret/private.png)
        """#.write(to: fileURL, atomically: true, encoding: .utf8)

        let html = try QuickLookPreviewRenderer().render(fileURL: fileURL)
        #expect(
            !html.contains(secretBytes.base64EncodedString()),
            "an image reference escaping the document directory must never be inlined into the preview"
        )
        #expect(html.contains(#"src="../secret/private.png""#))
    }

    @Test @MainActor
    func entitlementsGrantOnlySandboxAndReadOnlyFileAccess() throws {
        let entitlementsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // QuickLookSecurityTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("FenQuickLook/FenQuickLook.entitlements")
        let data = try Data(contentsOf: entitlementsURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let entitlements = try #require(plist)

        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-only"] as? Bool == true)
        // WKWebView's Networking/WebContent XPC helpers fail to launch inside a sandboxed
        // process without this entitlement, even when rendering is purely local -- it's required
        // for their process bootstrap, not for QuickLookPreviewRenderer to make any network call.
        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.server"] == nil)
        #expect(entitlements["com.apple.security.cs.allow-jit"] == nil)
        #expect(
            entitlements.count == 3,
            "entitlements must grant nothing beyond sandbox + read-only file access + network client"
        )
    }
}
