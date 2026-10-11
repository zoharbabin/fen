@testable import FenCore
import Foundation
import Testing

/// A bare repository standing in for GitHub, and any number of clones of it (issue #60).
/// The system git does the setup, so the tests don't depend on where Fen looks for git.
final class SyncFixture: @unchecked Sendable {
    static let repo = GitHubRepo(owner: "octo", name: "notes")

    let folder: TempFolder
    let secrets = MemorySecretStore()
    let sync: GitSync

    var remote: URL {
        folder.root.appendingPathComponent("remote.git", isDirectory: true)
    }

    /// `files` are on `main` in the remote.
    init(files: [String: String] = ["a.md": "# A\n", "notes/b.md": "# B\n"]) throws {
        folder = try TempFolder("sync")
        sync = GitSync(git: GitFixture.tool, secrets: secrets)
        let seed = try TempFolder("sync-seed")
        defer { seed.cleanUp() }
        try folder.git("init", "-q", "--bare", "-b", "main", remote.path)
        try seed.git("init", "-q", "-b", "main")
        for (path, text) in files {
            try seed.write(path, text)
        }
        try seed.git("add", "-A")
        try seed.git("commit", "-q", "-m", "init")
        try seed.git("push", "-q", remote.path, "main")
    }

    func cleanUp() {
        folder.cleanUp()
    }

    /// A clone of the remote, as the app makes it.
    func clone(_ name: String, githubOrigin: Bool = false) async throws -> URL {
        let target = try folder.folder(name)
        try await sync.clone(remote, into: target, token: nil)
        if githubOrigin {
            // git speaks to the local remote, while the origin reads as github.com.
            let url = Self.repo.cloneURL.absoluteString
            try git(target, "remote", "set-url", "origin", url)
            try git(target, "config", "url.\(remote.path).insteadOf", url)
        }
        return target
    }

    @discardableResult
    func git(_ directory: URL, _ arguments: String...) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "user.name=Other", "-c", "user.email=o@example.com", "-c", "commit.gpgsign=false"]
            + arguments
        process.currentDirectoryURL = directory
        process.environment = [
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "HOME": folder.root.path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commits `text` at `path` in `directory` and pushes, like a second device.
    func publish(_ path: String, _ text: String, from directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try git(directory, "add", "-A")
        try git(directory, "commit", "-q", "-m", "edit \(path)")
        try git(directory, "push", "-q", "origin", "main")
    }
}
