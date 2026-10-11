@testable import FenCore
import Foundation
import Testing

/// A real git repository in a temp folder, with one commit.
/// Tests use the system git so they don't depend on where Fen looks for it.
final class GitFixture: @unchecked Sendable {
    static let tool = GitTool(executable: URL(fileURLWithPath: "/usr/bin/git"))

    let folder: TempFolder
    let branches = AgentBranches(git: GitFixture.tool)

    var root: URL {
        folder.root
    }

    /// `files` are committed to `main`.
    init(_ files: [String: String] = ["a.md": "# A\n", "notes/b.md": "# B\n"], label: String = "git-agents") throws {
        folder = try TempFolder(label)
        try folder.git("init", "-q", "-b", "main")
        for (path, text) in files {
            try folder.write(path, text)
        }
        try folder.git("add", "-A")
        try folder.git("commit", "-q", "-m", "init")
    }

    func cleanUp() {
        folder.cleanUp()
    }

    @discardableResult
    func git(_ arguments: String...) throws -> String {
        try folder.git(arguments)
    }

    func branch(_ client: String, in directory: URL? = nil) async throws -> AgentBranch {
        try #require(await branches.open(directory: directory ?? root, client: client))
    }

    /// Commits `text` to `path` on the client's branch, from the branch's current tip.
    @discardableResult
    func commit(_ path: String, _ text: String?, as client: String, in directory: URL? = nil) async throws -> String {
        let branch = try await branch(client, in: directory)
        let tip = try await branches.tip(of: branch)
        return try await branches.commit(
            [AgentFileChange(path: path, data: text.map { Data($0.utf8) }, mode: nil)],
            message: AgentCommitMessage(subject: "Edit \(path)", trailers: [("Fen-Agent", client)]),
            on: branch,
            expectedTip: tip
        )
    }
}
