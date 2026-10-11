import AppKit
@testable import FenCore
import Foundation
import Highlightr
import SwiftUI
import Testing

private func inlineChunks(_ pieces: [String], done: Bool = true) -> [Data] {
    pieces.map { Data(#"data: {"choices":[{"delta":{"content":"\#($0)"}}]}"#.utf8 + Data("\n\n".utf8)) }
        + (done ? [Data("data: [DONE]\n\n".utf8)] : [])
}

final class DocumentBox {
    var text: String
    var edits: [EditorInsertion] = []
    init(_ text: String) {
        self.text = text
    }

    /// What a plain editor does with an edit. Real undo is covered by the editor tests below.
    func apply(_ edit: EditorInsertion) {
        text = (text as NSString).replacingCharacters(in: edit.range, with: edit.text)
        edits.append(edit)
    }
}

final class Flag: @unchecked Sendable {
    var on: Bool
    init(_ on: Bool = false) {
        self.on = on
    }
}

enum ProviderChoice {
    case none, local, remote
}

let inlineAIPlanText = """
# Plan

- Pricing per seat

Rewrite this clumsy sentence please.

ZEBRA-OTHER-PARAGRAPH stays out of selection requests.

"""

@MainActor
struct InlineAIFixture {
    let home: TempHome
    let notes: TempFolder
    let outside: TempFolder
    let library: WorkspaceLibrary
    let server: LoopbackServer
    let service: AIService
    let controller: InlineAIController
    let workspaceID: UUID
    let planURL: URL
    let outsideURL: URL
    let preview: Flag

    init(
        reply: [String] = ["A crisp sentence."],
        provider: ProviderChoice = .local,
        access: AIDataAccess = .localProvidersOnly,
        approval: ApprovalMode = .ask,
        holdOpen: Bool = false,
        done: Bool = true
    ) async throws {
        home = try TempHome()
        notes = try TempFolder("inline-notes")
        outside = try TempFolder("inline-outside")
        try notes.write(
            "pricing.md",
            "# Pricing\n\nIntro line.\n\n## Decision\n\n"
                + "We decided to charge per seat, not per usage. The price is twelve dollars per seat each month.\n"
        )
        planURL = try notes.write("plan.md", inlineAIPlanText)
        outsideURL = try outside.write("loose.md", inlineAIPlanText)
        let library = WorkspaceLibrary(home: home.home, watching: false, embedder: FakeEmbedder())
        let workspace = try library.add(folder: notes.root, name: "Notes")
        try library.updateSettings(id: workspace.id) {
            $0.aiDataAccess = access
            $0.approvalMode = approval
            $0.writePolicy.autoApproveConfirmed = approval == .autoApprove
        }
        let ready = try await pollUntilTrue(timeout: .seconds(30)) {
            let status = library.indexStatus(for: workspace.id)
            return status.phase == .idle && status.documents == 2
        }
        try #require(ready)
        let chunks = inlineChunks(reply, done: done)
        server = try await LoopbackServer.start { _ in
            LoopbackServer.Response(headers: ["Content-Type": "text/event-stream"], chunks: chunks, holdOpen: holdOpen)
        }
        let store = AIProviderStore(home: home.home, secrets: MemorySecretStore())
        switch provider {
        case .none: break
        case .local:
            try store.add(AIProviderConfig(
                name: "Local", kind: .openAICompatible, baseURL: "\(server.baseURL)/v1", model: "m"
            ))
        case .remote:
            try store.add(AIProviderConfig(
                name: "Cloud", kind: .openAICompatible, baseURL: "https://api.example.com/v1", model: "m"
            ))
        }
        service = AIService(store: store, workspaces: { library.registry.workspaces })
        self.library = library
        workspaceID = workspace.id
        let preview = Flag()
        self.preview = preview
        controller = InlineAIController(library: library, service: service, previewBeforeApplying: { preview.on })
    }

    func cleanUp() {
        server.stop()
        home.cleanUp()
        notes.cleanUp()
        outside.cleanUp()
    }

    func target(_ needle: String) throws -> EditorTarget {
        let range = (inlineAIPlanText as NSString).range(of: needle)
        return try #require(EditorTarget.resolve(in: inlineAIPlanText, selected: range))
    }

    func finish() async throws {
        let done = try await pollUntilTrue(timeout: .seconds(30)) {
            controller.phase != .idle && !controller.isWorking
        }
        try #require(done)
    }

    var sentText: String {
        var texts: [String] = []
        for request in server.requests {
            let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            for message in (body?["messages"] as? [[String: String]]) ?? [] {
                texts.append(message["content"] ?? "")
            }
        }
        return texts.joined(separator: "\n")
    }
}

@Suite("Inline Ask AI and Enrich: the controller (issue #6)", .serialized)
@MainActor
struct InlineAIControllerTests {
    private static let sentence = "Rewrite this clumsy sentence please."

    @Test("the answer is applied once, when it is complete, as one edit")
    func appliesOnce() async throws {
        let fixture = try await InlineAIFixture(reply: ["A crisp ", "sentence."])
        defer { fixture.cleanUp() }
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        try await fixture.finish()
        #expect(doc.edits.count == 1)
        #expect(doc.text == inlineAIPlanText.replacingOccurrences(of: Self.sentence, with: "A crisp sentence."))
        #expect(fixture.controller.phase == .applied("Done. Undo takes it back."))
    }

    @Test("the document is not touched while the answer streams, nor after Stop")
    func streamingNeverTouchesTheDocument() async throws {
        let fixture = try await InlineAIFixture(reply: ["Half an answer"], holdOpen: true, done: false)
        defer { fixture.cleanUp() }
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        let streaming = try await pollUntilTrue(timeout: .seconds(30)) {
            fixture.controller.streamed.contains("Half an answer")
        }
        try #require(streaming)
        #expect(fixture.controller.isWorking)
        #expect(doc.text == inlineAIPlanText)
        fixture.controller.cancel()
        let closed = try await pollUntilTrue(timeout: .seconds(30)) { fixture.server.clientClosed == 1 }
        try #require(closed)
        #expect(doc.text == inlineAIPlanText)
        #expect(doc.edits.isEmpty)
        #expect(fixture.controller.phase == .idle)
    }

    @Test("with Preview before applying, nothing changes until you apply, and Discard changes nothing")
    func previewWaits() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        fixture.preview.on = true
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        try await fixture.finish()
        guard case let .preview(proposal) = fixture.controller.phase else {
            Issue.record("expected a preview, got \(fixture.controller.phase)")
            return
        }
        #expect(proposal.replacement == "A crisp sentence.")
        #expect(doc.text == inlineAIPlanText)
        fixture.controller.discard()
        #expect(doc.text == inlineAIPlanText)
        fixture.controller.applyPreview()
        #expect(doc.text == inlineAIPlanText)
    }

    @Test("Apply from a preview makes the edit")
    func previewApplies() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        fixture.preview.on = true
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        try await fixture.finish()
        fixture.controller.applyPreview()
        #expect(doc.edits.count == 1)
        #expect(doc.text.contains("A crisp sentence."))
    }

    @Test("text that changed while Fen worked is never overwritten")
    func staleTextIsRefused() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        fixture.preview.on = true
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        try await fixture.finish()
        doc.text = inlineAIPlanText.replacingOccurrences(of: "clumsy", with: "awkward")
        let edited = doc.text
        fixture.controller.applyPreview()
        #expect(doc.text == edited)
        #expect(doc.edits.isEmpty)
        guard case .failed = fixture.controller.phase else {
            Issue.record("expected a failure, got \(fixture.controller.phase)")
            return
        }
    }

    @Test("selection scope sends only the selection. Document scope sends the whole document, for that call only")
    func scopes() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
        )
        try await fixture.finish()
        #expect(fixture.sentText.contains(Self.sentence))
        #expect(!fixture.sentText.contains("ZEBRA-OTHER-PARAGRAPH"))
        let first = fixture.server.requests.count
        // The edit moved the text, so aim a fresh target at the document as it is now.
        let now = doc.text
        let range = (now as NSString).range(of: "A crisp sentence.")
        fixture.controller.present(target: EditorTarget.resolve(in: now, selected: range))
        fixture.controller.rewrite(
            instruction: "Make it formal",
            scope: .document,
            document: now,
            fileURL: fixture.planURL
        )
        let again = try await pollUntilTrue(timeout: .seconds(30)) { fixture.server.requests.count == first + 1 }
        try #require(again)
        #expect(fixture.sentText.contains("ZEBRA-OTHER-PARAGRAPH"))
    }

    // MARK: - What may run

    @Test("with no provider nothing runs and nothing is sent")
    func noProvider() async throws {
        let fixture = try await InlineAIFixture(provider: .none)
        defer { fixture.cleanUp() }
        #expect(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .rewrite) != nil)
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "x",
            scope: .selection,
            document: inlineAIPlanText,
            fileURL: fixture.planURL
        )
        guard case .failed = fixture.controller.phase else {
            Issue.record("expected a failure, got \(fixture.controller.phase)")
            return
        }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("a workspace with AI access None is never sent to, even by a local provider")
    func accessNone() async throws {
        let fixture = try await InlineAIFixture(access: AIDataAccess.none)
        defer { fixture.cleanUp() }
        let reason = try #require(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .rewrite))
        #expect(reason.contains("Notes"))
        try fixture.controller.present(target: fixture.target(Self.sentence))
        fixture.controller.rewrite(
            instruction: "x",
            scope: .selection,
            document: inlineAIPlanText,
            fileURL: fixture.planURL
        )
        guard case .failed = fixture.controller.phase else {
            Issue.record("expected a failure, got \(fixture.controller.phase)")
            return
        }
        #expect(fixture.server.requests.isEmpty)
    }

    @Test("a remote provider is refused for a local-only workspace")
    func remoteForLocalOnly() async throws {
        let fixture = try await InlineAIFixture(provider: .remote, access: .localProvidersOnly)
        defer { fixture.cleanUp() }
        #expect(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .rewrite) != nil)
    }

    @Test("a remote provider is allowed when the workspace allows any provider")
    func remoteAllowed() async throws {
        let fixture = try await InlineAIFixture(provider: .remote, access: .anyConfiguredProvider)
        defer { fixture.cleanUp() }
        #expect(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .rewrite) == nil)
    }

    @Test("approval mode Off blocks the action")
    func approvalOff() async throws {
        let fixture = try await InlineAIFixture(approval: .off)
        defer { fixture.cleanUp() }
        let reason = try #require(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .rewrite))
        #expect(reason.contains("off"))
        #expect(fixture.controller.unavailableReason(fileURL: fixture.planURL, action: .enrich) != nil)
    }

    @Test("a file outside every workspace is shown to a local provider only")
    func outsideFile() async throws {
        let local = try await InlineAIFixture(provider: .local)
        defer { local.cleanUp() }
        #expect(local.controller.unavailableReason(fileURL: local.outsideURL, action: .rewrite) == nil)
        #expect(local.controller.unavailableReason(fileURL: nil, action: .rewrite) == nil)
        let remote = try await InlineAIFixture(provider: .remote, access: .anyConfiguredProvider)
        defer { remote.cleanUp() }
        #expect(remote.controller.unavailableReason(fileURL: remote.outsideURL, action: .rewrite) != nil)
        #expect(remote.controller.unavailableReason(fileURL: nil, action: .rewrite) != nil)
    }

    @Test("Enrich needs the file to be in a workspace")
    func enrichNeedsWorkspace() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        #expect(fixture.controller.unavailableReason(fileURL: fixture.outsideURL, action: .enrich) != nil)
    }

    // MARK: - Enrich

    @Test("Enrich adds a cited fact under the bullet, and the citation points at a real file and heading")
    func enrichCitesARealHeading() async throws {
        let fixture =
            try await InlineAIFixture(reply: ["B1:\\n- The price is twelve dollars per seat each month [1]\\n"])
        defer { fixture.cleanUp() }
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target("- Pricing per seat"))
        fixture.controller.enrich(document: inlineAIPlanText, fileURL: fixture.planURL)
        try await fixture.finish()
        guard case .applied = fixture.controller.phase else {
            Issue.record("expected the edit to apply, got \(fixture.controller.phase)")
            return
        }
        for line in inlineAIPlanText.components(separatedBy: "\n") where !line.isEmpty {
            #expect(doc.text.contains(line), "lost the original line: \(line)")
        }
        let lines = doc.text.components(separatedBy: "\n")
        let bulletIndex = try #require(lines.firstIndex(of: "- Pricing per seat"))
        let fact = lines[bulletIndex + 1]
        #expect(fact.contains("twelve dollars per seat"))
        let link = try #require(fact.range(of: #"\]\(([^)]+)\)"#, options: .regularExpression))
        let target = String(fact[link].dropFirst(2).dropLast())
        let parts = target.components(separatedBy: "#")
        let file = try String(contentsOf: fixture.notes.root.appendingPathComponent(parts[0]), encoding: .utf8)
        let slugs = file.components(separatedBy: "\n")
            .filter { $0.hasPrefix("#") }
            .map { HeadingAnchor.slug($0.drop(while: { $0 == "#" || $0 == " " }).description) }
        #expect(parts.count == 2)
        #expect(slugs.contains(parts[1]), "no heading with slug \(parts.last ?? "") in \(parts[0])")
    }

    @Test("with no supporting note, Enrich changes nothing, says why, and never asks the model")
    func enrichWithoutSupport() async throws {
        let fixture = try await InlineAIFixture()
        defer { fixture.cleanUp() }
        let lonely = "- Quokka migration schedule\n"
        let doc = DocumentBox(lonely)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        fixture.controller.present(target: EditorTarget.resolve(in: lonely, selected: NSRange(location: 0, length: 27)))
        fixture.controller.enrich(document: lonely, fileURL: fixture.planURL)
        try await fixture.finish()
        guard case let .notice(why) = fixture.controller.phase else {
            Issue.record("expected a notice, got \(fixture.controller.phase)")
            return
        }
        #expect(!why.isEmpty)
        #expect(doc.text == lonely)
        #expect(doc.edits.isEmpty)
    }

    @Test("a fact the model made up, with no matching note, is dropped")
    func enrichDropsUngroundedFacts() async throws {
        let fixture = try await InlineAIFixture(reply: ["B1:\\n- Bananas orbit Jupiter hourly [1]\\n"])
        defer { fixture.cleanUp() }
        let doc = DocumentBox(inlineAIPlanText)
        fixture.controller.bind(currentText: { doc.text }, insert: { doc.apply($0) })
        try fixture.controller.present(target: fixture.target("- Pricing per seat"))
        fixture.controller.enrich(document: inlineAIPlanText, fileURL: fixture.planURL)
        try await fixture.finish()
        #expect(doc.text == inlineAIPlanText)
        guard case .notice = fixture.controller.phase else {
            Issue.record("expected a notice, got \(fixture.controller.phase)")
            return
        }
    }
}

/// Drives a real `MarkdownNSTextView`: one Cmd+Z undoes a whole Ask AI result.
@Suite("Inline Ask AI in the real editor (issue #6)", .serialized)
@MainActor
struct InlineAIEditorE2ETests {
    private final class Box {
        var text = ""
    }

    private func makeEditor(_ box: Box) -> (MarkdownNSTextView, MarkdownTextView.Coordinator, NSWindow) {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let textStorage = CodeAttributedString()
        textStorage.language = "markdown"
        textStorage.highlightr.setTheme(to: "xcode")
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = MarkdownNSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        textView.isEditable = true
        textView.isRichText = true
        textView.allowsUndo = true
        textView.font = font
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.titled], backing: .buffered,
            defer: false
        )
        window.contentView = textView
        let parent = MarkdownTextView(
            text: Binding(get: { box.text }, set: { box.text = $0 }),
            font: font, highlightThemeName: "xcode", lineSpacing: 0, horizontalInset: 0, verticalInset: 0,
            isEditable: true, scrollsPastEnd: false, onSelectionChange: { _ in }, insertion: nil
        )
        let coordinator = parent.makeCoordinator()
        coordinator.textView = textView
        textView.delegate = coordinator
        return (textView, coordinator, window)
    }

    @Test("a streamed answer lands as one edit, and one Undo restores the original")
    func oneUndo() async throws {
        let fixture = try await InlineAIFixture(reply: ["A ", "crisp ", "sentence."])
        defer { fixture.cleanUp() }
        let box = Box()
        let (textView, coordinator, window) = makeEditor(box)
        defer { withExtendedLifetime(window) {} }
        do {
            window.makeFirstResponder(textView)
            textView.string = inlineAIPlanText
            box.text = inlineAIPlanText
            fixture.controller.bind(currentText: { box.text }, insert: { coordinator.apply($0, to: textView) })
            try fixture.controller.present(target: fixture.target("Rewrite this clumsy sentence please."))
            fixture.controller.rewrite(
                instruction: "Make it crisp", scope: .selection, document: inlineAIPlanText, fileURL: fixture.planURL
            )
            try await fixture.finish()
            let rewritten = inlineAIPlanText.replacingOccurrences(
                of: "Rewrite this clumsy sentence please.",
                with: "A crisp sentence."
            )
            #expect(textView.string == rewritten)
            #expect(box.text == rewritten)
            let undo = try #require(textView.undoManager)
            undo.undo()
            #expect(textView.string == inlineAIPlanText)
            #expect(box.text == inlineAIPlanText)
            #expect(!undo.canUndo || undo.undoActionName != "Typing")
        }
    }
}
