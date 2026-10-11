@testable import FenCore
import Foundation
import Testing
import UniformTypeIdentifiers

/// Issue #43: sharing a document out, and the declarations that let other apps open files in Fen.
struct ShareDocumentTests {
    @Test
    func theSharedFileIsNamedAfterTheDocumentWithAnMdExtension() {
        #expect(SharedMarkdown(name: "Trip notes", text: "").fileName == "Trip notes.md")
    }

    @Test
    func anUntitledDocumentGetsAName() {
        #expect(SharedMarkdown(name: "", text: "").fileName == "Untitled.md")
        #expect(SharedMarkdown(name: "  ..  ", text: "").fileName == "Untitled.md")
    }

    @Test
    func aTitleCannotLeaveTheTemporaryFolder() {
        let name = SharedMarkdown(name: "../../etc/pass:wd\\x", text: "").fileName
        #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\"))
        #expect(name.hasSuffix(".md") && !name.hasPrefix("."))
    }

    @Test
    func aLongTitleIsCut() {
        #expect(SharedMarkdown(name: String(repeating: "a", count: 300), text: "").fileName.count == 83)
    }

    @Test
    func theDocumentNameComesFromTheFileOrTheFirstHeading() {
        let document = MarkdownDocument(text: "# Heading title\n\nBody")
        #expect(SharedMarkdown(document: document).fileName == "Heading title.md")
        document.fileURL = URL(fileURLWithPath: "/tmp/plan.markdown")
        #expect(SharedMarkdown(document: document).fileName == "plan.md")
    }

    @Test @available(macOS 15.2, *)
    func theSharedFileHoldsTheDocumentText() async throws {
        let text = "# Title\n\nSome **bold** text and a ünïcode line.\n"
        let data = try await SharedMarkdown(name: "Note", text: text).exported(as: .markdown)
        #expect(String(bytes: data, encoding: .utf8) == text)
    }

    @Test @available(macOS 15.2, *)
    func textOnlyAppsGetTheMarkdownAsText() async throws {
        let data = try await SharedMarkdown(name: "Note", text: "# Hi").exported(as: .plainText)
        #expect(String(bytes: data, encoding: .utf8) == "# Hi")
    }

    // MARK: - Opening a file shared from another app

    private func iOSInfo() throws -> [String: Any] {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 1 ... 3 {
            root.deleteLastPathComponent()
        }
        let data = try Data(contentsOf: root.appendingPathComponent("iOS/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test
    func theIOSAppDeclaresEveryTypeItCanOpenAsAnEditor() throws {
        let info = try iOSInfo()
        let types = try #require(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let declared = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        for type in MarkdownDocument.readableContentTypes {
            #expect(declared.contains(type.identifier), "Info.plist doesn't declare \(type.identifier)")
        }
        #expect(types.allSatisfy { $0["CFBundleTypeRole"] as? String == "Editor" })
    }

    @Test
    func theIOSAppOpensSharedFilesInPlace() throws {
        let info = try iOSInfo()
        #expect(info["UISupportsDocumentBrowser"] as? Bool == true)
        #expect(info["LSSupportsOpeningDocumentsInPlace"] as? Bool == true)
    }

    @Test
    func everyMarkdownExtensionIsDeclaredForTheType() throws {
        let info = try iOSInfo()
        let imported = try #require(info["UTImportedTypeDeclarations"] as? [[String: Any]])
        let markdown = try #require(imported
            .first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try #require(markdown["UTTypeTagSpecification"] as? [String: Any])
        let extensions = try Set(#require(tags["public.filename-extension"] as? [String]))
        #expect(extensions == ["md", "markdown", "mdown", "mkd", "mkdn"])
    }
}
