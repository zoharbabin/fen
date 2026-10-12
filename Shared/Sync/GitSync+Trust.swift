import Foundation

/// Which folders Fen syncs. A repository's own `.git/config` can run programs (filters,
/// `core.sshCommand`, `core.fsmonitor`) or send requests somewhere else (`url.*.insteadOf`,
/// `http.proxy`), and those would run with the token in their environment. A folder you added from a
/// zip or a shared drive could carry such settings. So Fen syncs a folder it cloned itself, or one whose
/// settings are all on the short list below.
extension GitSync {
    /// Two-part keys a folder Fen didn't clone may set.
    static let safeConfigKeys: Set<String> = [
        "core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates", "core.ignorecase",
        "core.precomposeunicode", "core.symlinks", "core.autocrlf", "core.eol", "core.safecrlf", "core.quotepath",
        "core.untrackedcache", "core.checkstat", "core.trustctime", "extensions.objectformat", "pull.rebase",
        "pull.ff", "push.default", "push.autosetupremote",
    ]
    /// Sections whose keys only name things: `branch.<name>.*` and `user.*`.
    static let safeConfigSections: Set<String> = ["branch", "user"]
    /// Keys under `remote.<name>.`.
    static let safeRemoteKeys: Set<String> = ["url", "fetch", "tagopt", "prune", "prunetags"]

    /// Why Fen won't sync this folder, or `nil` when it will. Nothing here runs a program from the folder.
    func refusal(at root: URL) async -> String? {
        let prefix = try? await run(["rev-parse", "--show-prefix"], at: root, allowFailure: true)
        guard let prefix, prefix.succeeded else { return "This folder isn't a git repository." }
        // git lists paths from the top of the repository, so a folder inside one can't be synced safely.
        guard prefix.text.isEmpty else {
            return "Fen syncs a workspace only when its folder is the top of the git repository. "
                + "This folder is inside one. Add the repository's top folder as the workspace instead."
        }
        if clonedByFen {
            return nil
        }
        let list = try? await run(
            ["config", "--local", "--no-includes", "--list", "--name-only", "-z"],
            at: root,
            allowFailure: true
        )
        guard let list, list.succeeded else {
            return "Fen can't read this folder's git settings, so it won't sync it."
        }
        let names = list.stdout.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        let unsafe = Self.unsafeConfigKeys(names)
        guard unsafe.isEmpty else {
            return "Fen won't sync this folder, because its git settings could run programs or send your token "
                + "somewhere else: \(unsafe.prefix(5).joined(separator: ", ")). Clone the repository with Fen, "
                + "or remove those settings."
        }
        return nil
    }

    /// The keys of `names` (as `git config --name-only` prints them) that aren't on the safe list.
    static func unsafeConfigKeys(_ names: [String]) -> [String] {
        let unsafe = names.filter { name in
            let lower = name.lowercased()
            guard let first = lower.firstIndex(of: "."), let last = lower.lastIndex(of: ".") else { return true }
            let section = String(lower[..<first])
            if safeConfigKeys.contains(lower) || safeConfigSections.contains(section) {
                return false
            }
            let key = String(lower[lower.index(after: last)...])
            return !(section == "remote" && first != last && safeRemoteKeys.contains(key))
        }
        return Array(Set(unsafe)).sorted()
    }
}
