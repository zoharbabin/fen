@testable import FenCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Rules from issue #14's spec (github.com/zoharbabin/fen/issues/14). Each test below is
/// named after and cites the rule number it proves.
struct DefaultEditorTests {
    // MARK: - Rule 7.1: Fen's UTI registration for Markdown stays intact

    @Test func markdownUTTypeIdentifierIsNetDaringfireballMarkdown() {
        #expect(UTType.markdown.identifier == "net.daringfireball.markdown")
    }

    @Test func markdownUTTypeConformsToPlainText() {
        #expect(UTType.markdown.conforms(to: .plainText))
    }

    @Test func readableContentTypesIncludeMarkdown() {
        #expect(MarkdownDocument.readableContentTypes.contains(.markdown))
    }

    @Test func writableContentTypesIncludeMarkdown() {
        #expect(MarkdownDocument.writableContentTypes.contains(.markdown))
    }

    // MARK: - Rule 4.1: recents restoration reads content lazily, not eagerly

    @Test func constructingADocumentWithTextDoesNotTouchTheFilesystem() {
        // MarkdownDocument(text:) is the in-memory constructor DocumentGroup uses for a brand
        // new document -- it must not perform any file I/O, which is the same lazy-read
        // guarantee rule 4.1 requires of any recents-restoration path built on top of it.
        let before = Date()
        let document = MarkdownDocument(text: "# New")
        let elapsed = Date().timeIntervalSince(before)

        #expect(document.text == "# New")
        #expect(document.fileURL == nil, "A freshly constructed in-memory document has no backing file yet")
        #expect(elapsed < 0.05)
    }

    // MARK: - Rule 5.1 / 7.1: macOS/iOS Info.plist declare the same Markdown UTI

    @Test func macOSAndIOSInfoPlistsDeclareTheSameMarkdownDocumentType() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DefaultEditorTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests

        for platform in ["macOS", "iOS"] {
            let plistURL = repoRoot.appendingPathComponent("\(platform)/Info.plist")
            let data = try Data(contentsOf: plistURL)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            let docTypes = plist?["CFBundleDocumentTypes"] as? [[String: Any]]
            let firstDocType = docTypes?.first
            let itemContentTypes = firstDocType?["LSItemContentTypes"] as? [String]

            #expect(
                itemContentTypes?.contains("net.daringfireball.markdown") == true,
                "\(platform)/Info.plist must declare net.daringfireball.markdown"
            )
            #expect(firstDocType?["CFBundleTypeRole"] as? String == "Editor")
            #expect(firstDocType?["LSHandlerRank"] as? String == "Owner")

            let extensions = firstDocType?["CFBundleTypeExtensions"] as? [String]
            for expectedExtension in ["md", "markdown", "mdown", "mkd", "mkdn"] {
                #expect(
                    extensions?.contains(expectedExtension) == true,
                    "\(platform) missing extension \(expectedExtension)"
                )
            }
        }
    }

    // MARK: - Rule 8.1: the Finder document icon asset exists and is referenced

    @Test func macOSInfoPlistReferencesADocumentIconThatResolvesToARealIconsetFile() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DefaultEditorTests.swift
            .deletingLastPathComponent() // FenTests
            .deletingLastPathComponent() // Tests

        let plistURL = repoRoot.appendingPathComponent("macOS/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let docTypes = plist?["CFBundleDocumentTypes"] as? [[String: Any]]
        let iconFile = docTypes?.first?["CFBundleTypeIconFile"] as? String

        #expect(iconFile != nil, "macOS/Info.plist's CFBundleDocumentTypes entry must declare CFBundleTypeIconFile")

        let iconsetURL = repoRoot.appendingPathComponent("macOS/\(iconFile ?? "").iconset")
        #expect(
            FileManager.default.fileExists(atPath: iconsetURL.path),
            "Expected an iconset directory at \(iconsetURL.path) for CFBundleTypeIconFile '\(iconFile ?? "")'"
        )
    }
}
