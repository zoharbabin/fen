import Foundation

/// Two devices edited the same note (issue #62). Fen never picks a side. It merges what git can merge,
/// and leaves the rest as real conflict markers in the note, so both versions stay in the file and in
/// git history. A note that can't hold markers (an image, say) keeps your version, and the other
/// version is saved next to it as a copy. Nothing is pushed while a marker is left.
extension GitSync {
    enum MergeResult: Equatable {
        /// Merged and committed. `copies` are notes saved beside a file that can't hold markers.
        case merged(copies: [String])
        /// These notes hold markers. The merge waits until you edit them.
        case conflicts([String])
        /// Git didn't start the merge, and why. Nothing changed.
        case blocked(String)
    }

    /// Merges the remote branch into this one. Commit your changes first: git refuses to start a merge
    /// over an edit it would have to replace.
    func merge(at root: URL) async throws -> MergeResult {
        let out = try await git.run(
            Self.identity(at: root, using: self) + [
                "merge",
                "--no-edit",
                "--quiet",
                "-m",
                "Merge changes from GitHub",
                "@{u}",
            ],
            in: root
        )
        if out.succeeded {
            return .merged(copies: [])
        }
        guard await isMerging(at: root) else {
            return .blocked(Self.firstLine(out.stderr, fallback: "Git couldn't merge the changes."))
        }
        return try await settle(at: root, makeCopies: true)
    }

    /// Finishes a merge that waits on you, once no note still holds markers.
    /// - Returns: `nil` when no merge is waiting.
    func finishMerge(at root: URL) async throws -> MergeResult? {
        guard await isMerging(at: root) else { return nil }
        return try await settle(at: root, makeCopies: false)
    }

    func isMerging(at root: URL) async -> Bool {
        await (try? run(["rev-parse", "-q", "--verify", "MERGE_HEAD"], at: root, allowFailure: true))?.succeeded == true
    }

    /// Notes of a waiting merge that still hold conflict markers.
    func conflictedNotes(at root: URL) async throws -> [String] {
        guard await isMerging(at: root) else { return [] }
        var notes: [String] = []
        for path in try await unmergedPaths(at: root) where await holdsMarkers(path, at: root) {
            notes.append(path)
        }
        return notes
    }

    // MARK: - Steps

    /// `makeCopies` is on only right after git stopped the merge. Later, a note without markers is one
    /// you resolved by hand.
    private func settle(at root: URL, makeCopies: Bool) async throws -> MergeResult {
        let unmerged = try await unmergedPaths(at: root)
        var copies: [String] = []
        if makeCopies {
            for path in unmerged where await !holdsMarkers(path, at: root) {
                if let copy = try await keepBoth(path, at: root) {
                    copies.append(copy)
                }
            }
        }
        let waiting = try await conflictedNotes(at: root)
        guard waiting.isEmpty else { return .conflicts(waiting) }
        // Only the merged notes and their copies are staged. Your other edits stay yours to commit later.
        let list = Data((unmerged + copies).joined(separator: "\0").utf8) + Data([0])
        let add = try await git.run(
            ["add", "-A", "--pathspec-from-file=-", "--pathspec-file-nul"],
            in: root,
            input: list
        )
        guard add.succeeded else { throw SyncError.failed(Self.firstLine(add.stderr, fallback: "git add failed.")) }
        let commit = try await git.run(
            Self.identity(at: root, using: self) + ["commit", "--quiet", "--no-edit"],
            in: root
        )
        guard commit.succeeded else {
            throw SyncError.failed(Self.firstLine(commit.stderr, fallback: "git commit failed."))
        }
        return .merged(copies: copies)
    }

    /// A conflict with no markers in the file. When both sides changed it, your version stays and the
    /// other goes to a copy. When one side deleted it, the version that still exists stays.
    /// - Returns: The path of the copy, if one was made.
    private func keepBoth(_ path: String, at root: URL) async throws -> String? {
        let theirs = try await git.run(["show", ":3:\(path)"], in: root)
        let ours = try await git.run(["cat-file", "-e", ":2:\(path)"], in: root)
        var copy: String?
        if theirs.succeeded, ours.succeeded {
            let name = Self.copyName(for: path, at: root)
            try theirs.stdout.write(to: root.appendingPathComponent(name))
            copy = name
            _ = try await git.run(["checkout", "--ours", "--", path], in: root)
        }
        return copy
    }

    private func unmergedPaths(at root: URL) async throws -> [String] {
        let out = try await run(["diff", "--name-only", "--diff-filter=U", "-z"], at: root)
        return out.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.sorted()
    }

    // MARK: - Helpers

    /// Any one marker line left means the note isn't resolved yet. A `=======` line is also how Markdown
    /// underlines a heading, so it counts only when no version of the note in the merge has one.
    func holdsMarkers(_ path: String, at root: URL) async -> Bool {
        var separatorIsText = false
        for stage in 1 ... 3 {
            let blob = try? await git.run(["cat-file", "blob", ":\(stage):\(path)"], in: root)
            if let blob, blob.succeeded, Self.lines(of: blob.stdout).contains("=======") {
                separatorIsText = true
                break
            }
        }
        return Self.hasMarkers(at: root.appendingPathComponent(path), separatorIsText: separatorIsText)
    }

    static func hasMarkers(at url: URL, separatorIsText: Bool = false) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        return lines(of: data).contains { line in
            line.hasPrefix("<<<<<<< ") || line.hasPrefix(">>>>>>> ") || (!separatorIsText && line == "=======")
        }
    }

    /// The lines of a UTF-8 file without their line ends. Empty for anything else.
    private static func lines(of data: Data) -> [Substring] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        // `\r\n` is one Character in Swift, and `isNewline` matches it.
        return text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }

    /// `name (GitHub copy).ext`, or with a number when that name is taken.
    static func copyName(for path: String, at root: URL) -> String {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent().relativePath
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? "(GitHub copy)" : "(GitHub copy \(number))"
            let file = "\(stem) \(suffix)\(ext)"
            let candidate = directory == "." ? file : directory + "/" + file
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                return candidate
            }
            number += 1
        }
    }

    /// `-c` options that name the author when git has none configured.
    static func identity(at root: URL, using sync: GitSync) async -> [String] {
        let email = try? await sync.run(["config", "user.email"], at: root, allowFailure: true).text
        return email?.isEmpty == false ? [] : ["-c", "user.name=Fen", "-c", "user.email=fen@users.noreply.github.com"]
    }
}
