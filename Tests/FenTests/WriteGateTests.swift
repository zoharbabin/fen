@testable import FenCore
import Foundation
import Testing

@MainActor
@Suite("Write gate (issue #140)", .serialized)
struct WriteGateTests {
    // MARK: - Modes

    @Test("Ask holds the change and writes nothing until you approve")
    func askThenApprove() throws {
        let fx = try GateHarness()
        defer { fx.cleanUp() }
        let outcome = try fx.gate.submit(fx.change(.append(path: "a.md", text: "Two.")))
        guard case let .pending(item) = outcome else { Issue.record("expected pending, got \(outcome)")
            return
        }
        #expect(item.reason == .modeIsAsk)
        #expect(item.diff.added == 1)
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
        #expect(fx.gate.entries(for: fx.workspaceID).isEmpty)

        let entry = try fx.gate.approve(item.id)
        #expect(entry.approvedBy == .user)
        #expect(fx.text("a.md") == "# A\n\nOne.\nTwo.\n")
        #expect(fx.gate.pending.isEmpty)
    }

    @Test("rejecting a change leaves the file alone")
    func reject() throws {
        let fx = try GateHarness()
        defer { fx.cleanUp() }
        guard case let .pending(item) = try fx.gate.submit(fx.change(.append(path: "a.md", text: "Two."))) else {
            Issue.record("expected pending")
            return
        }
        fx.gate.reject(item.id)
        #expect(fx.gate.pending.isEmpty)
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
        #expect(throws: WriteError.unknownChange) { try fx.gate.approve(item.id) }
    }

    @Test("Off blocks the change")
    func off() throws {
        let fx = try GateHarness(settings: WorkspaceSettings(approvalMode: .off))
        defer { fx.cleanUp() }
        #expect(try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"))) == .blocked)
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
    }

    @Test("auto-approve applies an additive change straight away")
    func autoApplies() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        guard case let .applied(entry) = try fx.gate.submit(fx.change(.append(path: "a.md", text: "Two."))) else {
            Issue.record("expected applied")
            return
        }
        #expect(entry.approvedBy == .auto)
        #expect(entry.tier == .additive)
        #expect(fx.text("a.md") == "# A\n\nOne.\nTwo.\n")
    }

    @Test("auto-approve without the first-enable confirmation still asks")
    func unconfirmedAutoAsks() throws {
        let fx = try GateHarness(settings: WorkspaceSettings(approvalMode: .autoApprove))
        defer { fx.cleanUp() }
        guard case .pending = try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"))) else {
            Issue.record("expected pending")
            return
        }
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
    }

    @Test("a replacing edit asks unless the operation was opted in")
    func replacingOptIn() throws {
        let fx = try GateHarness(settings: autoSettings(replacing: false))
        defer { fx.cleanUp() }
        let edit = EditOperation.replaceText(path: "a.md", find: "One.", with: "Uno.")
        guard case let .pending(item) = try fx.gate.submit(fx.change(edit)) else { Issue.record("expected pending")
            return
        }
        #expect(item.reason == .replacingNotOptedIn)
        #expect(item.tier == .replacing)

        let migration = try fx.gate.submit(fx.change(edit), exemptFromReplacingOptIn: true)
        guard case .applied = migration else { Issue.record("a schema migration is exempt")
            return
        }
        #expect(fx.text("a.md") == "# A\n\nUno.\n")
    }

    @Test("destructive edits ask in auto-approve and nothing happens until approved", arguments: [
        EditOperation.delete(path: "a.md"),
        .overwrite(path: "a.md", content: "new\n"),
        .move(from: "a.md", to: "moved/a.md"),
    ])
    func destructiveAsks(edit: EditOperation) throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        guard case let .pending(item) = try fx.gate.submit(fx.change(edit, invoked: true)) else {
            Issue.record("expected pending")
            return
        }
        #expect(item.reason == .destructive)
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
        #expect(!fx.exists("moved/a.md"))
        _ = try fx.gate.approve(item.id)
        #expect(fx.text("a.md") != "# A\n\nOne.\n")
    }

    @Test("a change you start yourself applies in Ask mode")
    func invoked() throws {
        let fx = try GateHarness()
        defer { fx.cleanUp() }
        guard case let .applied(entry) = try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"), invoked: true))
        else {
            Issue.record("expected applied")
            return
        }
        #expect(entry.approvedBy == .invoked)
    }

    @Test("the pause switch makes auto-approve ask, survives a restart, and resumes")
    func pause() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        try fx.gate.setPaused(true)
        guard case let .pending(item) = try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"))) else {
            Issue.record("expected pending")
            return
        }
        #expect(item.reason == .paused)
        #expect(fx.restartedGate().isPaused)

        try fx.gate.setPaused(false)
        #expect(!fx.restartedGate().isPaused)
        guard case .applied = try fx.gate.submit(fx.change(.append(path: "a.md", text: "y"))) else {
            Issue.record("expected applied")
            return
        }
    }

    @Test("a client override can switch a path off while the workspace auto-approves")
    func overrideBlocks() throws {
        var settings = autoSettings()
        settings.writePolicy.overrides = [.init(kind: .pathGlob, match: "b.md", mode: .off)]
        let fx = try GateHarness(settings: settings)
        defer { fx.cleanUp() }
        #expect(try fx.gate.submit(fx.change(.append(path: "b.md", text: "x"))) == .blocked)
        guard case .applied = try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"))) else {
            Issue.record("expected applied")
            return
        }
    }

    // MARK: - Safety

    @Test("a stale result never overwrites a file you changed")
    func compareAndSwap() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        let change = try fx.change(.replaceText(path: "a.md", find: "One.", with: "Uno."))
        try fx.folder.write("a.md", "# A\n\nOne. And my own edit.\n")
        #expect(throws: WriteError.targetChanged("a.md")) { try fx.gate.submit(change) }
        #expect(fx.text("a.md") == "# A\n\nOne. And my own edit.\n")
    }

    @Test("a waiting change is dropped when the file changes before you approve")
    func staleApproval() throws {
        let fx = try GateHarness()
        defer { fx.cleanUp() }
        guard case let .pending(item) = try fx.gate.submit(fx.change(.append(path: "a.md", text: "x"))) else {
            Issue.record("expected pending")
            return
        }
        try fx.folder.write("a.md", "changed\n")
        #expect(throws: WriteError.targetChanged("a.md")) { try fx.gate.approve(item.id) }
        #expect(fx.text("a.md") == "changed\n")
        #expect(fx.gate.pending.isEmpty)
    }

    @Test("creating a file that appeared meanwhile is refused, and so is creating over an existing one")
    func createExisting() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        #expect(throws: WriteError.targetChanged("a.md")) {
            try fx.gate.submit(fx.change(.createFile(path: "a.md", content: "x"), base: .some(nil)))
        }
        #expect(throws: WriteError.alreadyExists("a.md")) {
            try fx.gate.submit(fx.change(.createFile(path: "a.md", content: "x")))
        }
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
    }

    @Test("an edit outside the run's scope is refused", arguments: ["b.md", "../outside.md", "/etc/hosts"])
    func outsideScope(path: String) throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        let change = try fx.change(.append(path: path, text: "x"), scope: ["a.md"], base: .some(nil))
        #expect(throws: WriteError.outsideScope(path)) { try fx.gate.submit(change) }
        #expect(fx.text("b.md") == "# B\n")
    }

    @Test(
        "paths that leave the workspace, hide, look secret, or hold a quote or control character are refused",
        arguments: [
            "../outside.md", "/etc/hosts", "notes/../../x.md", ".git/config", ".fen/schema.yaml", ".env",
            "keys/server.pem",
            "", "x.md\n0 0000000000000000000000000000000000000000\ta.md", "\"q.md\"", "tab\t.md",
        ]
    )
    func invalidPaths(path: String) throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        let change = try fx.change(.createFile(path: path, content: "x"), base: .some(nil))
        #expect(throws: WriteError.invalidPath(path)) { try fx.gate.submit(change) }
    }

    @Test("paths the workspace's exclude globs or .gitignore leave out are refused, existing or not")
    func excludedPaths() throws {
        var settings = autoSettings()
        settings.excludeGlobs = ["private/**"]
        let fx = try GateHarness(
            files: ["a.md": "# A\n", "private/p.md": "# P\n", "build/x.md": "# X\n"],
            settings: settings,
            git: true
        )
        defer { fx.cleanUp() }
        let changes: [(String, EditOperation, String??)] = [
            ("private/new.md", .createFile(path: "private/new.md", content: "x"), .some(nil)),
            ("private/p.md", .createFile(path: "private/p.md", content: "x"), .some(nil)),
            ("build/x.md", .append(path: "build/x.md", text: "x"), .some(ContentHash.of(Data("# X\n".utf8)))),
            ("private/a.md", .move(from: "a.md", to: "private/a.md"), nil),
        ]
        for (path, edit, base) in changes {
            let change = try fx.change(edit, base: base)
            #expect(throws: WriteError.invalidPath(path)) { try fx.gate.submit(change) }
        }
        #expect(!fx.exists("private/new.md"))
        #expect(fx.text("build/x.md") == "# X\n")
        #expect(fx.text("a.md") == "# A\n")
    }

    @Test("a symlink that points outside the workspace is refused")
    func symlinkEscape() throws {
        let fx = try GateHarness(settings: autoSettings())
        let outside = try TempFolder("outside")
        defer { fx.cleanUp()
            outside.cleanUp()
        }
        try outside.write("target.md", "secret\n")
        try fx.folder.symlink("link.md", to: outside.root.appendingPathComponent("target.md"))
        let change = try fx.change(.append(path: "link.md", text: "x"), base: .some(nil))
        #expect(throws: WriteError.invalidPath("link.md")) { try fx.gate.submit(change) }
        #expect(try String(contentsOf: outside.root.appendingPathComponent("target.md"), encoding: .utf8) == "secret\n")
    }

    @Test("a change can't reach another workspace, and an unknown workspace is refused")
    func crossWorkspace() throws {
        let fx = try GateHarness(settings: autoSettings())
        let other = try GateHarness(files: ["a.md": "other\n"], settings: autoSettings())
        defer { fx.cleanUp()
            other.cleanUp()
        }
        var change = try fx.change(.append(path: "a.md", text: "x"))
        change.workspaceID = UUID()
        #expect(throws: WriteError.unknownWorkspace) { try fx.gate.submit(change) }
        #expect(other.text("a.md") == "other\n")
        #expect(fx.text("a.md") == "# A\n\nOne.\n")
    }

    @Test("binary and oversized files are refused")
    func notText() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        try fx.folder.writeBytes("bin.md", [0xFF, 0xFE, 0x00, 0x80])
        #expect(throws: WriteError.notText("bin.md")) {
            try fx.gate.submit(fx.change(.append(path: "bin.md", text: "x"), base: .some(nil)))
        }
    }

    @Test("replace needs the text to appear exactly once")
    func replaceUnique() throws {
        let fx = try GateHarness(files: ["a.md": "x x\n"], settings: autoSettings())
        defer { fx.cleanUp() }
        #expect(throws: WriteError.findNotUnique(count: 2)) {
            try fx.gate.submit(fx.change(.replaceText(path: "a.md", find: "x", with: "y")))
        }
        #expect(throws: WriteError.findNotUnique(count: 0)) {
            try fx.gate.submit(fx.change(.replaceText(path: "a.md", find: "q", with: "y")))
        }
        #expect(fx.text("a.md") == "x x\n")
    }

    @Test("an edit that changes nothing is refused")
    func noChange() throws {
        let fx = try GateHarness(settings: autoSettings())
        defer { fx.cleanUp() }
        #expect(throws: WriteError.noChange) {
            try fx.gate.submit(fx.change(.replaceText(path: "a.md", find: "One.", with: "One.")))
        }
    }

    // MARK: - Caps

    @Test("a run over the file cap drops the rest to Ask")
    func fileCap() throws {
        let fx = try GateHarness(
            files: ["1.md": "1\n", "2.md": "2\n", "3.md": "3\n"],
            settings: autoSettings(maxFiles: 2)
        )
        defer { fx.cleanUp() }
        var outcomes: [WriteGate.Outcome] = []
        for name in ["1.md", "2.md", "3.md"] {
            try outcomes.append(fx.gate.submit(fx.change(.append(path: name, text: "x"))))
        }
        guard case .applied = outcomes[0], case .applied = outcomes[1], case let .pending(item) = outcomes[2] else {
            Issue.record("expected applied, applied, pending, got \(outcomes)")
            return
        }
        #expect(item.reason == .overCap)
        #expect(fx.text("3.md") == "3\n")
    }

    @Test("a replacing edit that changes too much of a document asks")
    func fractionCap() throws {
        let text = (1 ... 10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let fx = try GateHarness(files: ["a.md": text], settings: autoSettings(maxFraction: 0.3))
        defer { fx.cleanUp() }
        let small = EditOperation.replaceText(path: "a.md", find: "line 2\n", with: "two\n")
        guard case .applied = try fx.gate.submit(fx.change(small)) else { Issue.record("a small edit applies")
            return
        }

        let big = EditOperation.replaceText(path: "a.md", find: "line 4\nline 5\nline 6\nline 7\n", with: "x\n")
        guard case let .pending(item) = try fx.gate.submit(fx.change(big)) else {
            Issue.record("a big edit asks")
            return
        }
        #expect(item.reason == .overCap)
    }

    @Test("Approve All leaves deletes, moves, and whole-file replacements waiting")
    func approveAllSkipsDestructive() throws {
        let fx = try GateHarness(files: ["a.md": "# A\n", "b.md": "# B\n", "c.md": "# C\n", "d.md": "# D\n"])
        defer { fx.cleanUp() }
        let edits: [EditOperation] = [
            .append(path: "a.md", text: "More."),
            .replaceText(path: "b.md", find: "B", with: "Bee"),
            .delete(path: "c.md"),
            .move(from: "d.md", to: "e.md"),
            .overwrite(path: "a.md", content: "# New\n"),
        ]
        for edit in edits {
            try fx.gate.submit(fx.change(edit))
        }
        let batch = WorkspaceActivityView.batchApprovable(fx.gate.pending(for: fx.workspaceID))
        #expect(batch.approvable.map(\.change.edit.primaryPath) == ["a.md", "b.md"])
        #expect(batch.destructive == 3)
    }
}
