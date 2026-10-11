import Foundation

/// One `.gitignore`-style pattern. Used for `.gitignore` files and for a workspace's include and
/// exclude globs, so both follow the rules you already know from git (issue #5):
/// - A pattern without a slash matches at any depth. One with a slash is anchored to its base.
/// - A trailing `/` matches folders only. A leading `!` re-includes.
/// - `*` and `?` stay inside one path segment. `**` crosses segments.
struct GitIgnoreRule: Sendable {
    let isNegated: Bool
    let directoriesOnly: Bool
    private let regex: NSRegularExpression

    init?(line: String) {
        var pattern = Substring(line)
        // Trailing spaces are dropped unless escaped.
        while pattern.hasSuffix(" "), !pattern.hasSuffix("\\ ") {
            pattern = pattern.dropLast()
        }
        guard !pattern.isEmpty, !pattern.hasPrefix("#") else { return nil }
        var negated = false
        if pattern.hasPrefix("!") {
            negated = true
            pattern = pattern.dropFirst()
        } else if pattern.hasPrefix("\\!") || pattern.hasPrefix("\\#") {
            pattern = pattern.dropFirst()
        }
        var directoriesOnly = false
        if pattern.hasSuffix("/") {
            directoriesOnly = true
            pattern = pattern.dropLast()
        }
        guard !pattern.isEmpty else { return nil }
        let anchored = pattern.contains("/")
        if pattern.hasPrefix("/") {
            pattern = pattern.dropFirst()
        }
        let body = GitIgnoreRule.translate(String(pattern))
        let source = anchored ? "^\(body)$" : "^(?:.*/)?\(body)$"
        guard let regex = try? NSRegularExpression(pattern: source) else { return nil }
        isNegated = negated
        self.directoriesOnly = directoriesOnly
        self.regex = regex
    }

    func matches(_ path: String, isDirectory: Bool) -> Bool {
        if directoriesOnly, !isDirectory {
            return false
        }
        return regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) != nil
    }

    /// A `[...]` class starting at `start`. Returns the regex and the index of the last character used.
    /// A `[` with no closing `]` is a plain `[`.
    private static func characterClass(_ chars: [Character], from start: Int) -> (regex: String, last: Int) {
        guard let close = chars[(start + 1)...].firstIndex(of: "]"), close > start + 1 else {
            return ("\\[", start)
        }
        var inner = String(chars[(start + 1) ..< close])
        if inner.hasPrefix("!") {
            inner = "^" + inner.dropFirst()
        }
        return ("[" + inner.replacingOccurrences(of: "\\", with: "\\\\") + "]", close)
    }

    /// Glob to regex. `**/` spans folders, `*` and `?` stop at `/`, `[...]` is a character class.
    private static func translate(_ glob: String) -> String {
        let chars = Array(glob)
        var out = ""
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*":
                if index + 1 < chars.count, chars[index + 1] == "*" {
                    let atSegmentStart = index == 0 || chars[index - 1] == "/"
                    if atSegmentStart, index + 2 < chars.count, chars[index + 2] == "/" {
                        out += "(?:.*/)?"
                        index += 3
                        continue
                    }
                    out += atSegmentStart && index + 2 == chars.count ? ".*" : "[^/]*"
                    index += 2
                    continue
                }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "[":
                let (translated, last) = characterClass(chars, from: index)
                out += translated
                index = last
            case "\\":
                if index + 1 < chars.count {
                    index += 1
                    out += NSRegularExpression.escapedPattern(for: String(chars[index]))
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(char))
            }
            index += 1
        }
        return out
    }
}

/// The rules from one `.gitignore` file, applied to paths below `base`.
struct GitIgnoreRules: Sendable {
    /// Folder the file sits in, relative to the repo top. Empty for the top.
    let base: String
    let rules: [GitIgnoreRule]

    init(base: String, contents: String) {
        self.base = base
        rules = contents.split(whereSeparator: \.isNewline).compactMap { GitIgnoreRule(line: String($0)) }
    }

    /// `true` if ignored, `false` if re-included, `nil` if no rule matches.
    func verdict(for path: String, isDirectory: Bool) -> Bool? {
        guard let local = relative(path) else { return nil }
        var result: Bool?
        for rule in rules where rule.matches(local, isDirectory: isDirectory) {
            result = !rule.isNegated
        }
        return result
    }

    private func relative(_ path: String) -> String? {
        if base.isEmpty {
            return path
        }
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : nil
    }
}

/// The `.gitignore` files that apply at one place in a repo, outermost first. The last match wins.
struct GitIgnoreStack: Sendable {
    private var layers: [GitIgnoreRules] = []

    func adding(_ rules: GitIgnoreRules) -> GitIgnoreStack {
        var copy = self
        copy.layers.append(rules)
        return copy
    }

    /// `path` is relative to the repo top.
    func isIgnored(_ path: String, isDirectory: Bool) -> Bool {
        var ignored = false
        for layer in layers {
            if let verdict = layer.verdict(for: path, isDirectory: isDirectory) {
                ignored = verdict
            }
        }
        return ignored
    }
}

/// A workspace's include or exclude globs (gitignore syntax, no negation).
struct GlobSet: Sendable {
    private let rules: [GitIgnoreRule]

    init(_ globs: [String]) {
        rules = globs.compactMap { GitIgnoreRule(line: $0) }.filter { !$0.isNegated }
    }

    var isEmpty: Bool {
        rules.isEmpty
    }

    /// `true` if `path`, or any folder above it, matches. Like git, a matching folder covers its files.
    func matches(_ path: String) -> Bool {
        guard !rules.isEmpty else { return false }
        let parts = path.split(separator: "/").map(String.init)
        for depth in 1 ... parts.count {
            let prefix = parts[..<depth].joined(separator: "/")
            let isDirectory = depth < parts.count
            if rules.contains(where: { $0.matches(prefix, isDirectory: isDirectory) }) {
                return true
            }
        }
        return false
    }
}
