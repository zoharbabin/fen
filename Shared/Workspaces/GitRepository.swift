import CryptoKit
import Foundation

/// What Fen shows about a git work tree (issue #5).
public struct GitRepositoryState: Sendable, Equatable {
    /// Branch name, or the short commit when HEAD is detached.
    public let branch: String
    public let isDetached: Bool
    /// `true` when a tracked file differs from the index, a tracked file is gone, or an eligible
    /// file is untracked. `nil` when the index can't be read. Staged-but-uncommitted changes are
    /// not detected: that would mean reading git's object database.
    public let isDirty: Bool?
}

/// A git work tree, read from disk. Fen runs no `git` command and writes nothing here: the
/// system `git` isn't there on iOS, and on a Mac without the developer tools, running it opens an
/// install prompt.
public struct GitRepository: Sendable, Equatable {
    /// The folder that contains `.git`.
    public let workTree: URL
    let gitDirectory: URL

    /// Finds the work tree that holds `folder`, walking up through parents like git does.
    public static func detect(from folder: URL) -> GitRepository? {
        guard let canonical = PathGate.canonicalURL(of: folder) else { return nil }
        // Walk by path components, not `deletingLastPathComponent()`: on some macOS versions that
        // turns "/" into "/../", which never reaches a fixed point.
        var parts = canonical.pathComponents
        while !parts.isEmpty {
            let current = URL(fileURLWithPath: NSString.path(withComponents: parts), isDirectory: true)
            let marker = current.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return GitRepository(workTree: current, gitDirectory: marker)
                }
                if let target = gitDirectoryFromPointerFile(marker, workTree: current) {
                    return GitRepository(workTree: current, gitDirectory: target)
                }
            }
            parts.removeLast()
        }
        return nil
    }

    /// A `.git` file (linked worktree or submodule) holds `gitdir: <path>`.
    private static func gitDirectoryFromPointerFile(_ file: URL, workTree: URL) -> URL? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("gitdir:") }) else {
            return nil
        }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        return path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : workTree.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    // MARK: - Branch

    public func branch() -> (name: String, isDetached: Bool)? {
        guard let head = try? String(contentsOf: gitDirectory.appendingPathComponent("HEAD"), encoding: .utf8) else {
            return nil
        }
        let text = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ref:") {
            let ref = text.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let name = ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
            return (name, false)
        }
        return (String(text.prefix(7)), true)
    }

    // MARK: - Ignore rules

    /// The `.gitignore` rules that apply at the top of `root`: `info/exclude`, then each
    /// `.gitignore` from the work tree down to `root`. Paths are matched relative to the work tree.
    func ignoreStack(forRoot root: URL) -> GitIgnoreStack {
        var stack = GitIgnoreStack()
        if let exclude = readExclude() {
            stack = stack.adding(GitIgnoreRules(base: "", contents: exclude))
        }
        let rootParts = relativeParts(of: root) ?? []
        for depth in 0 ... rootParts.count {
            let parts = Array(rootParts[..<depth])
            let directory = parts.reduce(workTree) { $0.appendingPathComponent($1) }
            stack = stack.addingIgnoreFile(in: directory, base: parts.joined(separator: "/"))
        }
        return stack
    }

    /// Path components of `url` below the work tree, or `nil` if it is outside.
    func relativeParts(of url: URL) -> [String]? {
        guard let canonical = PathGate.canonicalURL(of: url) else { return nil }
        let tree = workTree.pathComponents
        let parts = canonical.pathComponents
        guard parts.starts(with: tree) else { return nil }
        return Array(parts.dropFirst(tree.count))
    }

    private func readExclude() -> String? {
        var directory = gitDirectory
        if let common = try? String(contentsOf: gitDirectory.appendingPathComponent("commondir"), encoding: .utf8) {
            let path = common.trimmingCharacters(in: .whitespacesAndNewlines)
            directory = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : gitDirectory.appendingPathComponent(path).standardizedFileURL
        }
        return try? String(contentsOf: directory.appendingPathComponent("info/exclude"), encoding: .utf8)
    }

    // MARK: - Dirty state

    /// Compares the tracked files under `root` with the index. `eligible` are the files Fen lists,
    /// as paths relative to `root`. Returns `nil` when the index can't be read.
    func isDirty(root: URL, eligible: [String]) -> Bool? {
        guard let data = try? Data(contentsOf: gitDirectory.appendingPathComponent("index")),
              let entries = GitIndex.parse(data),
              let rootParts = relativeParts(of: root) else { return nil }
        let prefix = rootParts.isEmpty ? "" : rootParts.joined(separator: "/") + "/"
        var tracked = Set<String>()
        for (count, entry) in entries.enumerated() where entry.path.hasPrefix(prefix) {
            if count % 256 == 0, Task.isCancelled {
                return nil
            }
            tracked.insert(entry.path)
            if entry.isConflicted || entry.differs(from: workTree) {
                return true
            }
        }
        return eligible.contains { !tracked.contains(prefix + $0) }
    }
}

extension GitIgnoreStack {
    /// Adds `directory/.gitignore` if it exists. `base` is the folder's path below the work tree.
    func addingIgnoreFile(in directory: URL, base: String) -> GitIgnoreStack {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(".gitignore"), encoding: .utf8) else {
            return self
        }
        return adding(GitIgnoreRules(base: base, contents: text))
    }
}

// MARK: - Index

struct GitIndexEntry {
    let path: String
    let size: UInt32
    let mtimeSeconds: UInt32
    let mtimeNanoseconds: UInt32
    let sha1: Data
    let mode: UInt32
    let stage: Int

    var isConflicted: Bool {
        stage != 0
    }

    /// Symlinks (120000) and submodules (160000) are skipped. Everything else is compared by
    /// existence, size, and modification time, then by content hash if only the time differs.
    func differs(from workTree: URL) -> Bool {
        if mode == 0o120000 || mode == 0o160000 {
            return false
        }
        var info = stat()
        guard lstat(workTree.appendingPathComponent(path).path, &info) == 0 else { return true }
        if UInt32(truncatingIfNeeded: info.st_size) != size {
            return true
        }
        if UInt32(truncatingIfNeeded: info.st_mtimespec.tv_sec) == mtimeSeconds,
           UInt32(truncatingIfNeeded: info.st_mtimespec.tv_nsec) == mtimeNanoseconds {
            return false
        }
        guard let content = try? Data(contentsOf: workTree.appendingPathComponent(path)) else { return true }
        var blob = Data("blob \(content.count)\0".utf8)
        blob.append(content)
        return Data(Insecure.SHA1.hash(data: blob)) != sha1
    }
}

enum GitIndex {
    /// Reads index versions 2, 3, and 4. Returns `nil` for anything else or a damaged file.
    static func parse(_ data: Data) -> [GitIndexEntry]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0 ..< 4].elementsEqual("DIRC".utf8) else { return nil }
        let version = be32(bytes, 4)
        let count = Int(be32(bytes, 8))
        guard (2 ... 4).contains(version) else { return nil }
        var entries: [GitIndexEntry] = []
        entries.reserveCapacity(count)
        var offset = 12
        var previousPath: [UInt8] = []
        for _ in 0 ..< count {
            let start = offset
            guard offset + 62 <= bytes.count else { return nil }
            let mtimeSeconds = be32(bytes, offset + 8)
            let mtimeNanoseconds = be32(bytes, offset + 12)
            let mode = be32(bytes, offset + 24)
            let size = be32(bytes, offset + 36)
            let sha1 = Data(bytes[offset + 40 ..< offset + 60])
            let flags = Int(bytes[offset + 60]) << 8 | Int(bytes[offset + 61])
            offset += 62
            if version >= 3, flags & 0x4000 != 0 {
                offset += 2
            }
            var pathBytes: [UInt8]
            if version == 4 {
                guard let (strip, next) = readOffsetVarint(bytes, at: offset), strip <= previousPath.count else {
                    return nil
                }
                offset = next
                guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
                pathBytes = Array(previousPath.dropLast(strip)) + bytes[offset ..< end]
                offset = end + 1
            } else {
                guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
                pathBytes = Array(bytes[offset ..< end])
                offset = start + ((end + 1 - start + 7) & ~7)
            }
            previousPath = pathBytes
            // A path that isn't UTF-8 can't be a listed file, so skip it.
            guard let path = String(bytes: pathBytes, encoding: .utf8) else { continue }
            entries.append(GitIndexEntry(
                path: path,
                size: size,
                mtimeSeconds: mtimeSeconds,
                mtimeNanoseconds: mtimeNanoseconds,
                sha1: sha1,
                mode: mode,
                stage: (flags >> 12) & 0x3
            ))
        }
        return entries
    }

    private static func be32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    /// Git's offset varint, used for the v4 strip length.
    private static func readOffsetVarint(_ bytes: [UInt8], at start: Int) -> (value: Int, next: Int)? {
        guard start < bytes.count else { return nil }
        var cursor = start + 1
        var byte = Int(bytes[start])
        var result = byte & 0x7F
        while byte & 0x80 != 0 {
            guard cursor < bytes.count else { return nil }
            byte = Int(bytes[cursor])
            cursor += 1
            result = ((result + 1) << 7) + (byte & 0x7F)
        }
        return (result, cursor)
    }
}
